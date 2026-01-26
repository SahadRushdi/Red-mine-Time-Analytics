# frozen_string_literal: true

class CustomHolidaysController < ApplicationController
  layout 'admin'
  self.main_menu = false
  menu_item :custom_holidays
  
  before_action :require_admin
  before_action :find_holiday, only: [:edit, :update, :destroy]

  def index
    @holiday_count = CustomHoliday.count
    @holiday_pages = Paginator.new @holiday_count, 25, params['page']
    @holidays = CustomHoliday.order(start_date: :desc)
                              .limit(@holiday_pages.per_page)
                              .offset(@holiday_pages.offset)
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
