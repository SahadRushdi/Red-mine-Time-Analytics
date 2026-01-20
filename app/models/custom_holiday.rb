# frozen_string_literal: true

class CustomHoliday < ActiveRecord::Base
  validates :name, presence: true
  validates :start_date, presence: true
  validates :end_date, presence: true
  validate :end_date_after_start_date

  scope :active, -> { where(active: true) }
  scope :in_date_range, ->(from_date, to_date) {
    where('(start_date <= ? AND end_date >= ?) OR (start_date <= ? AND end_date >= ?) OR (start_date >= ? AND end_date <= ?)',
          to_date, from_date, to_date, to_date, from_date, to_date)
  }

  def self.is_holiday?(date)
    active.where('start_date <= ? AND end_date >= ?', date, date).exists?
  end

  def self.holidays_between(from_date, to_date)
    holidays = []
    active.in_date_range(from_date, to_date).find_each do |holiday|
      # Get the actual date range within the query period
      start_d = [holiday.start_date, from_date].max
      end_d = [holiday.end_date, to_date].min
      
      (start_d..end_d).each do |date|
        holidays << date
      end
    end
    holidays.uniq.sort
  end

  def self.count_holidays(from_date, to_date)
    holidays_between(from_date, to_date).count
  end

  def duration_days
    (end_date - start_date).to_i + 1
  end

  private

  def end_date_after_start_date
    return if end_date.blank? || start_date.blank?

    if end_date < start_date
      errors.add(:end_date, 'must be after or equal to start date')
    end
  end
end
