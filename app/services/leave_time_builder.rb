# frozen_string_literal: true
class LeaveTimeBuilder
  MONTHLY_LEAVE_TYPES = Settings.leave_types.to_a.select { |lt| lt.second['creation'] == 'monthly' }
  JOIN_DATE_BASED_LEAVE_TYPES = Settings.leave_types.to_a.select { |lt| lt.second['creation'] == 'join_date_based' }
  JOIN_DATE_BASED_LEED_DAY = Settings.leed_days.join_date_based.day

  def initialize(user)
    @user = user
  end

  def automatically_import(by_assign_date: false)
    monthly_import by_assign_date: by_assign_date
    join_date_based_import by_assign_date: by_assign_date
  end

  def join_date_based_import(by_assign_date: false, prebuild: false)
    JOIN_DATE_BASED_LEAVE_TYPES.each do |leave_type, config|
      build_join_date_based_leave_types(leave_type, config, by_assign_date, prebuild)
    end
  end

  def monthly_import(by_assign_date: false, prebuild: false)
    MONTHLY_LEAVE_TYPES.each do |leave_type, config|
      build_monthly_leave_types(leave_type, config, by_assign_date, prebuild)
    end
  end

  private

  def build_join_date_based_leave_types(leave_type, config, build_by_assign_date = false, prebuild)
    return unless user_can_have_leave_type?(@user, config)
    quota = extract_quota(config, @user, prebuild: prebuild)
    if build_by_assign_date
      join_date_based_by_assign_date(leave_type, quota)
    else
      join_anniversary = @user.next_join_anniversary
      expiration_date = join_anniversary.next_year - 1.day
      create_leave_time(leave_type, quota, join_anniversary, expiration_date)
    end
  end

  def join_date_based_by_assign_date(leave_type, quota)
    if @user.assign_date < @user.join_date
      date = @user.join_date
      expiration_date = date.next_year - 1.day
    else
      date = @user.assign_date
      expiration_date = if date.month > @user.join_date.month or (date.month == @user.join_date.month and date.day >= @user.join_date.day)
                          Date.parse("#{date.next_year.year}/#{@user.join_date.month}/#{@user.join_date.day}") - 1.day
                        else
                          Date.parse("#{date.year}/#{@user.join_date.month}/#{@user.join_date.day}") - 1.day
                        end
    end
    return if @user.assign_date > Time.current.to_date.next_year
    while date <= Time.zone.now.to_date
      create_leave_time(leave_type, quota, date, expiration_date)
      date = expiration_date + 1.day
      expiration_date = date.next_year - 1.day
    end
    create_leave_time(leave_type, quota, date, expiration_date) if Time.zone.now.to_date + JOIN_DATE_BASED_LEED_DAY >= date or @user.join_date + 1.year >= Time.zone.now.to_date
  end

  def build_monthly_leave_types(leave_type, config, build_by_assign_date = false, prebuild)
    quota = extract_quota(config, @user, prebuild: prebuild)
    if build_by_assign_date
      date = @user.assign_date >= @user.join_date ? @user.assign_date : @user.join_date
      while date <= Time.zone.now.to_date
        expiration_date = date.end_of_month
        create_leave_time(leave_type, quota, date, expiration_date)
        date = date.next_month.beginning_of_month
      end
    else
      @effective_date  = prebuild ? Time.zone.today.next_month.beginning_of_month : Time.zone.today
      @expiration_date = prebuild ? Time.zone.today.next_month.end_of_month : Time.zone.today.end_of_month
      create_leave_time(leave_type, quota, @effective_date, @expiration_date)
    end
  end

  def create_leave_time(leave_type, quota, effective_date, expiration_date)
    @user.leave_times.create(
      leave_type: leave_type,
      quota: quota,
      usable_hours: quota,
      used_hours: 0,
      effective_date: effective_date,
      expiration_date: expiration_date
    )
  end

  def extract_quota(config, user, prebuild: false)
    return config['quota'] * 8 if config['quota'].is_a? Integer
    seniority = prebuild ? user.seniority(user.next_join_anniversary) : user.seniority
    return config['quota']['maximum_quota'] if seniority >= config['quota']['maximum_seniority']
    config['quota']['values'][seniority.to_s.to_sym] * 8
  end

  def user_can_have_leave_type?(user, config)
    return true if config['quota'].is_a? Integer
    config['quota']['type'] != 'seniority_based' || user.fulltime?
  end
end
