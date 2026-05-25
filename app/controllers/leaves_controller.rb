# frozen_string_literal: true

class LeavesController < ApplicationController
  menu_item :leaves
  before_action :require_admin

  def index
    @users = User.active.sorted
    @default_from = parse_date(params[:from]) || Date.current.beginning_of_month
    @default_to = parse_date(params[:to]) || Date.current
    @filter_status = params[:status].to_s.presence
    @filter_user_id = params[:user_id].to_s.presence
    @selected_user = @filter_user_id.present? ? User.find_by(id: @filter_user_id) : nil
  end

  def data
    render json: leaves_payload(filter_params)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def create
    user_id = manual_leave_params[:user_id].to_s
    user = User.find_by(id: user_id)
    return render json: { error: 'User is required' }, status: :unprocessable_entity if user.nil?

    from_date = parse_date(manual_leave_params[:from])
    to_date = parse_date(manual_leave_params[:to]) || from_date
    return render json: { error: 'From date is required' }, status: :unprocessable_entity if from_date.nil?
    return render json: { error: 'From date must be earlier than To date' }, status: :unprocessable_entity if from_date > to_date

    leave_fraction = manual_leave_params[:leave_fraction].to_f
    unless [TaLeaveRecord::HALF_DAY_FRACTION, TaLeaveRecord::FULL_DAY_FRACTION].include?(leave_fraction)
      return render json: { error: 'Leave fraction must be 0.5 or 1' }, status: :unprocessable_entity
    end

    created = 0
    recipient_email = TaTeamSetting.leave_sync_settings[:recipient_email]
    TaLeaveRecord.transaction do
      (from_date..to_date).each do |date|
        record = TaLeaveRecord.find_or_initialize_by(user_id: user.id, leave_date: date)
        record.assign_attributes(
          leave_fraction: leave_fraction,
          status: 'confirmed',
          sender_email: TaLeaveRecord.user_email(user),
          recipient_email: recipient_email,
          raw_subject: 'Manual entry',
          sync_mode: 'manual',
          source_sent_at: Time.zone.now
        )
        record.save!
        created += 1
      end
    end

    render json: { ok: true, created: created }, status: :ok
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update_status
    @leave_record = TaLeaveRecord.find(params[:id])
    status = params[:status].to_s
    unless @leave_record.status == 'flagged' && status == 'confirmed'
      return render json: { error: 'Only flagged records can be unflagged' }, status: :unprocessable_entity
    end
    mapped_user = @leave_record.user || TaLeaveRecord.find_active_user_by_sender(@leave_record.sender_email)
    if mapped_user.nil?
      return render json: { error: 'Cannot unflag this record because sender is not mapped to a Redmine user' }, status: :unprocessable_entity
    end

    @leave_record.update!(
      status: 'confirmed',
      user_id: mapped_user.id,
      leave_fraction: effective_leave_fraction(@leave_record)
    )
    render json: { ok: true, record_id: @leave_record.id, status: @leave_record.status }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Leave record not found' }, status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def update
    leave_record = TaLeaveRecord.find(params[:id])
    leave_fraction = params[:leave_fraction].to_f
    leave_date = parse_date(params[:leave_date])

    unless leave_fraction.between?(0, 1)
      return render json: { error: 'Leave fraction must be between 0 and 1' }, status: :unprocessable_entity
    end

    if leave_date.nil?
      return render json: { error: 'Leave date is required' }, status: :unprocessable_entity
    end

    leave_record.update!(
      leave_fraction: leave_fraction,
      leave_date: leave_date
    )

    render json: {
      ok: true,
      record_id: leave_record.id,
      leave_date: leave_record.leave_date.to_s,
      leave_fraction: leave_record.leave_fraction.to_f.round(2),
      leave_type: leave_type_for_fraction(leave_record.leave_fraction)
    }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Leave record not found' }, status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    leave_record = TaLeaveRecord.find(params[:id])
    unless %w[confirmed flagged].include?(leave_record.status)
      return render json: { error: 'Only confirmed or flagged records can be deleted' }, status: :unprocessable_entity
    end

    leave_record.destroy!
    render json: { ok: true, deleted: true, record_id: params[:id] }, status: :ok
  rescue ActiveRecord::RecordNotFound
    render json: { error: 'Leave record not found' }, status: :not_found
  rescue StandardError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def filter_params
    params.permit(:from, :to, :user_id, :status)
  end

  def manual_leave_params
    params.permit(:user_id, :from, :to, :leave_fraction)
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
      next if record.status == 'flagged'

      user_totals[record.user_id] += effective_leave_fraction(record)
    end

    {
      filters: { from: from_date, to: to_date, user_id: filters[:user_id].to_s, status: filters[:status].to_s },
      totals: {
        overall_leave_days: records.select { |r| r.status == 'confirmed' }.sum { |record| effective_leave_fraction(record) }.round(2),
        users_with_leave: user_totals.keys.compact.count,
        flagged_records: records.count { |record| record.status == 'flagged' },
        total_records: records.count
      },
      daily_groups: grouped_by_date.map do |date, group_records|
        {
          date: date,
          total_leave_days: group_records.select { |r| r.status == 'confirmed' }.sum { |record| effective_leave_fraction(record) }.round(2),
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
    mapped_user = record.user || TaLeaveRecord.find_active_user_by_sender(record.sender_email)
    leave_fraction = effective_leave_fraction(record)
      {
        id: record.id,
        user_id: mapped_user&.id,
        user_name: mapped_user&.name || record.sender_email,
        sender_email: record.sender_email.to_s,
      leave_date: record.leave_date,
      leave_fraction: leave_fraction.round(2),
      leave_type: leave_type_for_fraction(leave_fraction),
        status: record.status,
        flagged_reason: flagged_reason_for(record),
        ai_analyzed: ai_analyzed?(record),
        can_unflag: record.status == 'flagged' && mapped_user.present?,
        can_delete: %w[confirmed flagged].include?(record.status),
        can_edit: true,
        subject: record.raw_subject.to_s
      }
  end

  def effective_leave_fraction(record)
    stored = record.leave_fraction.to_f
    return stored if stored.positive?

    parsed = parse_leave_record(record)
    parsed.leave_fraction.to_f
  end

  def parse_leave_record(record)
    subject = record.raw_subject.to_s.sub(/\A\[FLAGGED:[^\]]+\]\s*/, '')
    recipient_email = record.recipient_email.to_s.presence || TaTeamSetting.leave_sync_settings[:recipient_email]
    parser = RedmineTimeAnalytics::LeaveEmailParser.new
    parser.parse(
      message: {
        from: record.sender_email,
        to: recipient_email,
        subject: subject,
        body: record.raw_body,
        sent_at: record.source_sent_at || record.created_at || Time.zone.now
      },
      recipient_email: recipient_email
    )
  rescue StandardError
    nil
  end

  def parse_date(value)
    raw = value.to_s.strip
    return nil if raw.blank?

    Date.strptime(raw, '%m/%d/%Y')
  rescue ArgumentError, TypeError
    Date.parse(raw)
  rescue ArgumentError, TypeError
    nil
  end

  def leave_type_for_fraction(fraction)
    value = fraction.to_f
    return 'Full Day' if value >= 1
    return 'Half Day' if value >= 0.5

    'Unknown'
  end

  def flagged_reason_for(record)
    return '' unless record.status == 'flagged'

    raw_reason = record.raw_subject.to_s[/\A\[FLAGGED:([^\]]+)\]/, 1].to_s
    return '' if raw_reason.blank?

    text = raw_reason.tr('_', ' ').strip.split.map(&:capitalize).join(' ')
    text.gsub(/\bAi\b/, 'AI')
  end

  def ai_analyzed?(record)
    record.sync_mode.to_s.include?('_ai')
  end
end
