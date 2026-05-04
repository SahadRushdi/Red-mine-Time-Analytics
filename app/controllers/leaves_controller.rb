# frozen_string_literal: true

class LeavesController < ApplicationController
  menu_item :leaves
  before_action :require_admin

  def index
    @users = User.active.sorted
    @default_from = Date.current.beginning_of_month
    @default_to = Date.current
    @filter_status = params[:status].to_s.presence
    @filter_user_id = params[:user_id].to_s.presence
  end

  def data
    render json: leaves_payload(filter_params)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update_status
    @leave_record = TaLeaveRecord.find(params[:id])
    status = params[:status].to_s
    unless @leave_record.status == 'flagged' && status == 'confirmed'
      return render json: { error: 'Only flagged records can be unflagged' }, status: :unprocessable_entity
    end
    if @leave_record.user_id.blank?
      return render json: { error: 'Cannot unflag this record because sender is not mapped to a Redmine user' }, status: :unprocessable_entity
    end

    @leave_record.update!(status: 'confirmed')
    render json: { ok: true, record_id: @leave_record.id, status: @leave_record.status }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Leave record not found' }, status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def filter_params
    params.permit(:from, :to, :user_id, :status)
  end

  def leaves_payload(filters)
    from_date = parse_date(filters[:from]) || Date.current.beginning_of_month
    to_date = parse_date(filters[:to]) || Date.current
    raise ArgumentError, 'From date must be earlier than To date' if from_date > to_date

    scope = TaLeaveRecord.includes(:user).within_range(from_date, to_date)
    scope = scope.where(user_id: filters[:user_id].to_i) if filters[:user_id].present?
    scope = scope.where(status: filters[:status].to_s) if filters[:status].present? && TaLeaveRecord::STATUSES.include?(filters[:status].to_s)

    records = scope.order(leave_date: :asc, user_id: :asc, source_sent_at: :asc).to_a
    grouped_by_date = records.group_by(&:leave_date)
    user_totals = Hash.new(0.0)
    records.each do |record|
      next if record.user_id.blank?

      user_totals[record.user_id] += record.leave_fraction.to_f
    end

    {
      filters: { from: from_date, to: to_date, user_id: filters[:user_id].to_s, status: filters[:status].to_s },
      totals: {
        overall_leave_days: records.sum { |record| record.leave_fraction.to_f }.round(2),
        users_with_leave: user_totals.keys.compact.count,
        flagged_records: records.count { |record| record.status == 'flagged' },
        total_records: records.count
      },
      daily_groups: grouped_by_date.map do |date, group_records|
        {
          date: date,
          total_leave_days: group_records.sum { |record| record.leave_fraction.to_f }.round(2),
          records: group_records.map { |record| serialize_record(record) }
        }
      end,
      user_summary: user_totals.map do |user_id, total|
        user = records.find { |record| record.user_id == user_id }&.user
        {
          user_id: user_id,
          user_name: user&.name || 'Unknown User',
          total_leave_days: total.round(2)
        }
      end.sort_by { |entry| [-entry[:total_leave_days], entry[:user_name]] }
    }
  end

  def serialize_record(record)
    {
      id: record.id,
      user_id: record.user_id,
      user_name: record.user&.name || record.sender_email,
      leave_date: record.leave_date,
      leave_fraction: record.leave_fraction.to_f.round(2),
      leave_type: record.leave_fraction.to_f >= 1 ? 'Full Day' : 'Half Day',
      status: record.status,
      can_unflag: record.status == 'flagged' && record.user_id.present?,
      subject: record.raw_subject.to_s
    }
  end

  def parse_date(value)
    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end
end
