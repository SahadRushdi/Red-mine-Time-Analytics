# Business Time Configuration for Sri Lankan Working Days
# This configuration sets up the working hours and holidays for Sri Lanka

require 'business_time'
require 'holidays'

# Configure business_time gem
BusinessTime::Config.tap do |config|
  # Set working days (Monday to Friday, excluding Saturday and Sunday)
  config.beginning_of_workday = "9:00 am"
  config.end_of_workday = "5:00 pm"
  
  # Define non-working days (weekends)
  config.work_week = [:mon, :tue, :wed, :thu, :fri]
  
  # Load Sri Lankan holidays
  # The holidays gem will automatically handle public holidays and Poya days for Sri Lanka
  config.holidays << lambda { |date|
    # Use the holidays gem to check if the date is a Sri Lankan holiday
    # :lk is the ISO 3166-1 alpha-2 code for Sri Lanka
    Holidays.on(date, :lk, :observed).any?
  }
end
