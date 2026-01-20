# frozen_string_literal: true

module RedmineTimeAnalytics
  class SriLankanHolidays
    # Fixed Public Holidays in Sri Lanka
    FIXED_PUBLIC_HOLIDAYS = [
      [2, 4],   # Independence Day
      [5, 1],   # May Day
      [12, 25], # Christmas Day
      [12, 31]  # Special Bank Holiday (Last day of the year)
    ].freeze

    # Fixed Mercantile/Bank Holidays
    MERCANTILE_HOLIDAYS = [
      [1, 15],  # Tamil Thai Pongal Day
      [4, 13],  # Sinhala and Tamil New Year's Eve
      [4, 14]   # Sinhala and Tamil New Year Day
    ].freeze

    # Full Moon Poya Days (Buddhist holidays) - these vary by lunar calendar
    # These are approximate dates for 2024-2026, should be updated annually
    # or calculated using lunar calendar library
    POYA_DAYS_2024 = [
      Date.new(2024, 1, 25),  # Duruthu Poya
      Date.new(2024, 2, 23),  # Navam Poya
      Date.new(2024, 3, 24),  # Medin Poya
      Date.new(2024, 4, 23),  # Bak Poya
      Date.new(2024, 5, 23),  # Vesak Poya
      Date.new(2024, 6, 21),  # Poson Poya
      Date.new(2024, 7, 20),  # Esala Poya
      Date.new(2024, 8, 19),  # Nikini Poya
      Date.new(2024, 9, 17),  # Binara Poya
      Date.new(2024, 10, 17), # Vap Poya
      Date.new(2024, 11, 15), # Il Poya
      Date.new(2024, 12, 14)  # Unduvap Poya
    ].freeze

    POYA_DAYS_2025 = [
      Date.new(2025, 1, 13),  # Duruthu Poya
      Date.new(2025, 2, 12),  # Navam Poya
      Date.new(2025, 3, 13),  # Medin Poya
      Date.new(2025, 4, 12),  # Bak Poya
      Date.new(2025, 5, 12),  # Vesak Poya
      Date.new(2025, 6, 10),  # Poson Poya
      Date.new(2025, 7, 10),  # Esala Poya
      Date.new(2025, 8, 8),   # Nikini Poya
      Date.new(2025, 9, 7),   # Binara Poya
      Date.new(2025, 10, 6),  # Vap Poya
      Date.new(2025, 11, 5),  # Il Poya
      Date.new(2025, 12, 4)   # Unduvap Poya
    ].freeze

    POYA_DAYS_2026 = [
      Date.new(2026, 1, 3),  # Duruthu Poya
      Date.new(2026, 2, 1),  # Navam Poya
      Date.new(2026, 3, 2),   # Medin Poya
      Date.new(2026, 4, 1),   # Bak Poya
      Date.new(2026, 5, 1),   # Vesak Poya (overlaps with May Day)
      Date.new(2026, 5, 30),  # Poson Poya
      Date.new(2026, 6, 29),  # Esala Poya
      Date.new(2026, 7, 29),  # Nikini Poya
      Date.new(2026, 8, 27),  # Binara Poya
      Date.new(2026, 9, 26),  # Vap Poya
      Date.new(2026, 10, 25), # Il Poya
      Date.new(2026, 11, 24), # Unduvap Poya
      Date.new(2026, 12, 23)  # Unduvap Poya (if two in same month)
    ].freeze

    # Islamic Holidays (Ramadan, Hajj) - also vary by lunar calendar
    # These are approximate dates and should be updated annually
    ISLAMIC_HOLIDAYS_2024 = [
      Date.new(2024, 9, 16)   # Milad-un-Nabi (Prophet's Birthday)
    ].freeze

    ISLAMIC_HOLIDAYS_2025 = [
      Date.new(2025, 9, 5)    # Milad-un-Nabi (Prophet's Birthday)
    ].freeze

    ISLAMIC_HOLIDAYS_2026 = [
      Date.new(2026, 8, 26)   # Milad-un-Nabi (Prophet's Birthday)
    ].freeze

    class << self
      # Check if a given date is a holiday in Sri Lanka (includes custom holidays)
      def holiday?(date)
        fixed_public_holiday?(date) || 
        mercantile_holiday?(date) || 
        poya_day?(date) || 
        islamic_holiday?(date) ||
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

      # Check if a date is a fixed public holiday
      def fixed_public_holiday?(date)
        FIXED_PUBLIC_HOLIDAYS.include?([date.month, date.day])
      end

      # Check if a date is a mercantile holiday
      def mercantile_holiday?(date)
        MERCANTILE_HOLIDAYS.include?([date.month, date.day])
      end

      # Check if a date is a Poya day (Buddhist full moon holiday)
      def poya_day?(date)
        poya_days_for_year(date.year).include?(date)
      end

      # Check if a date is an Islamic holiday
      def islamic_holiday?(date)
        islamic_holidays_for_year(date.year).include?(date)
      end

      # Get all Poya days for a specific year
      def poya_days_for_year(year)
        case year
        when 2024
          POYA_DAYS_2024
        when 2025
          POYA_DAYS_2025
        when 2026
          POYA_DAYS_2026
        else
          # For years not defined, return empty array
          # In production, you should implement lunar calendar calculation
          # or maintain a database of holidays
          []
        end
      end

      # Get all Islamic holidays for a specific year
      def islamic_holidays_for_year(year)
        case year
        when 2024
          ISLAMIC_HOLIDAYS_2024
        when 2025
          ISLAMIC_HOLIDAYS_2025
        when 2026
          ISLAMIC_HOLIDAYS_2026
        else
          []
        end
      end

      # Get all holidays between two dates
      def holidays_between(from_date, to_date)
        holidays = []
        (from_date..to_date).each do |date|
          holidays << date if holiday?(date)
        end
        
        # Also get custom holidays
        if defined?(CustomHoliday) && CustomHoliday.respond_to?(:holidays_between)
          custom_holidays = CustomHoliday.holidays_between(from_date, to_date)
          holidays.concat(custom_holidays)
        end
        
        holidays.uniq.sort
      end

      # Count holidays between two dates
      def count_holidays(from_date, to_date)
        holidays_between(from_date, to_date).count
      end
    end
  end
end
