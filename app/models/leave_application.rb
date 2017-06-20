# frozen_string_literal: true
class LeaveApplication < ApplicationRecord
  include AASM
  include SignatureConcern

  enum status:     Settings.leave_applications.statuses
  enum leave_type: Settings.leave_applications.leave_types

  acts_as_paranoid
  paginates_per 15

  before_validation :assign_hours
  after_create  :create_leave_time_usages
  after_update  :update_leave_time_usages

  belongs_to :user
  belongs_to :manager, class_name: 'User', foreign_key: 'manager_id'
  has_many   :leave_times, through: :leave_time_usages
  has_many   :leave_time_usages
  has_many   :leave_hours_by_dates, dependent: :delete_all

  validates :leave_type, :description, :start_time, :end_time, presence: true

  validate :hours_should_be_positive_integer
  validate :should_not_overlaps_other_applications

  scope :leave_within_range, ->(beginning = Daikichi::Config::Biz.periods.after(1.month.ago.beginning_of_month).first.start_time, closing = Daikichi::Config::Biz.periods.before(1.month.ago.end_of_month).first.end_time.localtime) {
    where(
      '(leave_applications.start_time, leave_applications.end_time) OVERLAPS (timestamp :beginning, timestamp :closing)',
      beginning: beginning, closing: closing
    )
  }

  scope :personal, ->(user_id, beginning, ending, status_array = ['pending', 'approved']) {
    where(status: status_array, user_id: user_id).leave_within_range(beginning, ending)
  }

  scope :with_status, ->(status) { where(status: status) }
  scope :with_year,   ->(year = Time.current.year) {
    leave_within_range(Time.zone.local(year).beginning_of_year, Time.zone.local(year).end_of_year)
  }

  aasm column: :status, enum: true do
    state :pending, initial: true
    state :approved
    state :rejected
    state :canceled

    event :approve, after: [proc { |manager| sign(manager) }] do
      transitions to: :approved, from: :pending, after: :transfer_locked_hours_to_used_hours
    end

    event :reject, after: proc { |manager| sign(manager) } do
      transitions to: :rejected, from: :pending, after: :return_leave_time_usable_hours
    end

    event :revise, after: proc { |params| update_leave_application(params) } do
      transitions to: :pending, from: [:pending, :approved]
    end

    event :cancel do
      transitions to: :canceled, from: :pending, after: :return_leave_time_usable_hours
      transitions to: :canceled, from: :approved, unless: :happened?, after: :return_approved_application_usable_hours
    end
  end

  ransacker :start_date do
    Arel.sql("DATE((#{table_name}.start_time AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Taipei')")
  end

  ransacker :end_date do
    Arel.sql("DATE((#{table_name}.end_time AT TIME ZONE 'UTC') AT TIME ZONE 'Asia/Taipei')")
  end

  def self.leave_hours_within(beginning = Daikichi::Config::Biz.periods.after(1.month.ago.beginning_of_month).first.start_time,
                              closing   = Daikichi::Config::Biz.periods.before(1.month.ago.end_of_month).first.end_time)
    self.leave_within_range(beginning, closing).reduce(0) do |result, la|
      if la.range_exceeded?(beginning, closing)
        @valid_range = [la.start_time, beginning].max..[la.end_time, closing].min
        result + Daikichi::Config::Biz.within(@valid_range.min, @valid_range.max).in_minutes / 60.0
      else
        result + la.hours
      end
    end
  end

  def happened?
    Time.current > self.start_time
  end

  def range_exceeded?(beginning = Daikichi::Config::Biz.periods.after(1.month.ago.beginning_of_month).first.start_time,
                      closing   = Daikichi::Config::Biz.periods.before(1.month.ago.end_of_month).first.end_time)
    beginning > self.start_time || closing < self.end_time
  end

  def leave_type?(type = :all)
    return true if type.to_sym == :all
    self.leave_type.to_sym == type.to_sym
  end

  def available_leave_times
    self.user.leave_times
      .where(leave_type: Settings.leave_applications.available_quota_types.send(self.leave_type))
      .where('usable_hours > 0')
      .overlaps(start_time.beginning_of_day, end_time.end_of_day)
      .order(order_by_sequence)
      .order(:expiration_date, :usable_hours)
  end

  def interval_changed?
    @interval_changed ||= self.new_record? || self.start_time_changed? || self.end_time_changed?
  end

  private

  def assign_hours
    self.hours = auto_calculated_minutes / 60
  end

  def auto_calculated_minutes
    return @minutes = 0 unless start_time && end_time
    @minutes ||= Daikichi::Config::Biz.within(start_time, end_time).in_minutes
  end

  def hours_should_be_positive_integer
    return if self.errors[:start_time].any? or self.errors[:end_time].any?
    errors.add(:end_time, :not_integer) if (@minutes % 60).nonzero? || !self.hours.positive?
    errors.add(:start_time, :should_be_earlier) unless self.end_time > self.start_time
  end

  def should_not_overlaps_other_applications
    return if self.errors[:start_time].any? or self.errors[:end_time].any?
    overlapped = LeaveApplication.personal(user_id, start_time, end_time).where.not(id: self.id)
    return unless overlapped.any?
    overlap_application_error_messages(overlapped)
  end

  def overlap_application_error_messages(leave_applications)
    url = Rails.application.routes.url_helpers
    leave_applications.each do |la|
      errors.add(
        :base,
        I18n.t(
          'activerecord.errors.models.leave_application.attributes.base.overlap_application',
          leave_type: LeaveApplication.human_enum_value(:leave_type, la.leave_type),
          start_time: la.start_time.to_formatted_s(:month_date),
          end_time:   la.end_time.to_formatted_s(:month_date),
          link:       url.leave_application_path({ id: la.id })
        )
      )
    end
  end

  def order_by_sequence
    format 'array_position(Array%s, leave_type::TEXT)', Settings.leave_applications.available_quota_types.send(self.leave_type).to_s.tr('"', "'")
  end

  def create_leave_time_usages
    raise ActiveRecord::Rollback unless LeaveTimeUsageBuilder.new(self).build_leave_time_usages
  end

  def update_leave_application(resource_params)
    self.update(resource_params)
  end

  def update_leave_time_usages
    return unless self.start_time_changed? or self.end_time_changed? or self.description_changed?
    case aasm.from_state
    when :pending then return_leave_time_usable_hours
    when :approved then return_approved_application_usable_hours
    end
    create_leave_time_usages
  end

  def transfer_locked_hours_to_used_hours
    self.leave_time_usages.each { |usage| usage.leave_time.use_hours!(usage.used_hours) }
  end

  def revert_used_hours_to_locked_hours
    self.leave_time_usages.each { |usage| usage.leave_time.unuse_and_lock_hours!(usage.used_hours) }
  end

  def return_leave_time_usable_hours
    self.leave_time_usages.each do |usage|
      usage.leave_time.unlock_hours!(usage.used_hours)
      usage.destroy
    end
  end

  def return_approved_application_usable_hours
    self.leave_time_usages.each do |usage|
      usage.leave_time.unuse_hours!(usage.used_hours)
      usage.destroy
    end
  end
end

class LeaveApplication::ActiveRecord_Associations_CollectionProxy
  def leave_hours_within_month(type: 'all', year: Time.current.year, month: Time.current.month)
    beginning = Daikichi::Config::Biz.periods.after(Time.zone.local(year, month, 1)).first.start_time
    closing   = Daikichi::Config::Biz.periods.before(Time.zone.local(year, month, 1).end_of_month).first.end_time
    records.select { |r| r.leave_type?(type) }.reduce(0) do |result, la|
      if la.range_exceeded?(beginning, closing)
        @valid_range = [la.start_time, beginning].max..[la.end_time, closing].min
        result + Daikichi::Config::Biz.within(@valid_range.min, @valid_range.max).in_minutes / 60.0
      else
        result + la.hours
      end
    end
  end
end
