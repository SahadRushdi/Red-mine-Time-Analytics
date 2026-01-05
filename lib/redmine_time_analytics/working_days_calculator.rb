# frozen_string_literal: true

require_relative 'sri_lankan_holidays'

module RedmineTimeAnalytics
  class WorkingDaysCalculator
    include Redmine::Utils::DateCalculation

    class << self
      # Calculate the number of working days between two dates
      # Excludes weekends (from Redmine settings) and Sri Lankan holidays
      def working_days_count(from_date, to_date)
        return 0 if from_date > to_date
        
        total_days = (to_date - from_date).to_i + 1
        
        # Count weekend days using Redmine's logic
        weekend_days = count_weekend_days(from_date, to_date)
        
        # Count Sri Lankan holidays (excluding those that fall on weekends)
        holidays = count_working_day_holidays(from_date, to_date)
        
        # Calculate working days
        working_days = total_days - weekend_days - holidays
        
        # Ensure we don't return negative values
        [working_days, 0].max
      end

      # Check if a date is a working day
      def working_day?(date)
        !weekend?(date) && !SriLankanHolidays.holiday?(date)
      end

      # Check if a date is a weekend
      def weekend?(date)
        non_working_week_days.include?(date.cwday)
      end

      private

      # Count weekend days between two dates
      def count_weekend_days(from_date, to_date)
        return 0 if from_date > to_date
        
        count = 0
        (from_date..to_date).each do |date|
          count += 1 if weekend?(date)
        end
        count
      end

      # Count holidays that fall on working days (not weekends)
      def count_working_day_holidays(from_date, to_date)
        return 0 if from_date > to_date
        
        holidays = SriLankanHolidays.holidays_between(from_date, to_date)
        
        # Count only holidays that don't fall on weekends
        holidays.count { |holiday| !weekend?(holiday) }
      end

      # Get non-working week days from Redmine settings
      # Default to Saturday (6) and Sunday (7) if not configured
      def non_working_week_days
        @non_working_week_days ||= begin
          days = Setting.non_working_week_days
          if days.is_a?(Array) && days.size < 7
            days.map(&:to_i)
          else
            # Default to Saturday and Sunday
            [6, 7]
          end
        end
      end
    end
  end
end
