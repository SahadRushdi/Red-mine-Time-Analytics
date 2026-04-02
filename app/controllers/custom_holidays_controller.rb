# frozen_string_literal: true

class CustomHolidaysController < ApplicationController
  include SortHelper

  helper :sort
  layout 'admin'
  self.main_menu = false
  menu_item :custom_holidays
  
  before_action :require_admin
  before_action :find_holiday, only: [:edit, :update, :destroy]

  def index
    sort_init 'start_date', 'desc'
    sort_update 'name' => 'custom_holidays.name',
                'start_date' => 'custom_holidays.start_date'

    holidays_scope = CustomHoliday.order(sort_clause)
    @holiday_count = holidays_scope.count
    @holiday_pages = Paginator.new @holiday_count, 25, params['page']
    @holidays = holidays_scope.offset(@holiday_pages.offset).limit(@holiday_pages.per_page).to_a
  end

  def new
    @holiday = CustomHoliday.new
  end

  def create
    @holiday = CustomHoliday.new(holiday_params)
    if @holiday.save
      flash[:notice] = 'Holiday was successfully created.'
      redirect_to custom_holidays_path
    else
      render :new
    end
  end

  def edit
  end

  def update
    if @holiday.update(holiday_params)
      flash[:notice] = 'Holiday was successfully updated.'
      redirect_to custom_holidays_path
    else
      render :edit
    end
  end

  def destroy
    @holiday.destroy
    flash[:notice] = 'Holiday was successfully deleted.'
    redirect_to custom_holidays_path
  end

  def import_csv
    unless params[:csv_file]
      flash[:error] = 'Please select a CSV file to upload.'
      redirect_to custom_holidays_path
      return
    end

    file = params[:csv_file]
    
    unless file.original_filename.end_with?('.csv')
      flash[:error] = 'Invalid file format. Please upload a CSV file.'
      redirect_to custom_holidays_path
      return
    end

    require 'csv'
    
    imported_count = 0
    errors = []
    line_number = 1

    begin
      CSV.foreach(file.path, headers: true, skip_blanks: true) do |row|
        line_number += 1
        
        # Skip empty rows
        next if row.to_h.values.compact.empty?
        
        name = row['Name']&.strip
        start_date_str = row['Start Date']&.strip
        end_date_str = row['End Date']&.strip
        description = row['Description']&.strip

        # Validate required fields
        if name.blank?
          errors << "Line #{line_number}: Name is required"
          next
        end

        if start_date_str.blank?
          errors << "Line #{line_number}: Start date is required"
          next
        end

        # Parse dates
        begin
          start_date = Date.parse(start_date_str)
        rescue ArgumentError
          errors << "Line #{line_number}: Invalid start date format '#{start_date_str}'"
          next
        end

        # If end_date is empty, use start_date (single day holiday)
        end_date = if end_date_str.blank?
                     start_date
                   else
                     begin
                       Date.parse(end_date_str)
                     rescue ArgumentError
                       errors << "Line #{line_number}: Invalid end date format '#{end_date_str}'"
                       next
                     end
                   end

        # Create holiday
        holiday = CustomHoliday.new(
          name: name,
          start_date: start_date,
          end_date: end_date,
          description: description,
          active: true
        )

        if holiday.save
          imported_count += 1
        else
          errors << "Line #{line_number}: #{holiday.errors.full_messages.join(', ')}"
        end
      end

      if imported_count > 0
        flash[:notice] = "Successfully imported #{imported_count} holiday(s)."
      end

      if errors.any?
        flash[:warning] = "Import completed with #{errors.count} error(s): #{errors.first(5).join('; ')}"
      end

    rescue CSV::MalformedCSVError => e
      flash[:error] = "Invalid CSV file: #{e.message}"
    rescue => e
      flash[:error] = "An error occurred: #{e.message}"
    end

    redirect_to custom_holidays_path
  end

  private

  def find_holiday
    @holiday = CustomHoliday.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def holiday_params
    params.require(:custom_holiday).permit(:name, :start_date, :end_date, :description, :active)
  end
end
