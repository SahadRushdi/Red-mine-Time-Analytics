# frozen_string_literal: true

module RedmineTimeAnalytics
  class Holidays
    class << self
      # Check if a given date is a holiday (only checks custom holidays from database)
      def holiday?(date)
        custom_holiday?(date)
      end

      # Check if a date is a custom holiday (from database)
      def custom_holiday?(date)
        # Check if CustomHoliday model exists and has the method
        if defined?(CustomHoliday) && CustomHoliday.respond_to?(:is_holiday?)
          CustomHoliday.is_holiday?(date)
        else
          false
        end
      end

      # Get all holidays between two dates (from database)
      def holidays_between(from_date, to_date)
        if defined?(CustomHoliday) && CustomHoliday.respond_to?(:holidays_between)
          CustomHoliday.holidays_between(from_date, to_date)
        else
          []
        end
      end

      # Count holidays between two dates
      def count_holidays(from_date, to_date)
        holidays_between(from_date, to_date).count
      end
    end
  end
end
