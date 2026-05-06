# frozen_string_literal: true

class TaLeaveRecord < ActiveRecord::Base
  self.table_name = 'ta_leave_records'

  STATUSES = %w[confirmed flagged].freeze
  HALF_DAY_FRACTION = 0.5
  FULL_DAY_FRACTION = 1.0

  belongs_to :user, optional: true

  validates :user_id, presence: true, if: :confirmed?
  validates :leave_date, presence: true
  validates :leave_fraction, presence: true, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 }
  validates :status, presence: true, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: { scope: :leave_date }, allow_nil: true

  scope :confirmed, -> { where(status: 'confirmed') }
  scope :flagged, -> { where(status: 'flagged') }
  scope :within_range, ->(from_date, to_date) { where(leave_date: from_date..to_date) }

  class << self
    def upsert_from_email!(attrs)
      user = attrs[:user]
      leave_date = attrs.fetch(:leave_date)
      leave_fraction = attrs.fetch(:leave_fraction)
      status = attrs.fetch(:status, 'confirmed')
      sender_email = extract_email(attrs[:sender_email])
      recipient_email = extract_email(attrs[:recipient_email])
      source_message_id = attrs[:source_message_id].to_s.strip.presence

      if status == 'confirmed' && user.nil?
        raise ArgumentError, 'Confirmed leave records require a mapped user'
      end

      record = if user.present?
                 find_or_initialize_by(user_id: user.id, leave_date: leave_date)
               elsif source_message_id.present?
                 find_or_initialize_by(source_message_id: source_message_id)
               else
                 find_or_initialize_by(sender_email: sender_email, leave_date: leave_date, status: 'flagged')
               end
      incoming_sent_at = attrs[:source_sent_at]

      if record.persisted? && incoming_sent_at.present? && record.source_sent_at.present?
        return record if record.source_sent_at > incoming_sent_at && record.status == 'confirmed'
      end

      if status == 'flagged' && user.present? && record.persisted? && record.status == 'confirmed'
        return record
      end

      record.assign_attributes(
        user_id: user&.id,
        leave_date: leave_date,
        leave_fraction: leave_fraction,
        status: status,
        sender_email: sender_email,
        recipient_email: recipient_email,
        source_message_id: source_message_id,
        source_thread_id: attrs[:source_thread_id],
        source_sent_at: incoming_sent_at,
        raw_subject: attrs[:raw_subject].to_s[0, 1000],
        raw_body: attrs[:raw_body],
        sync_mode: attrs[:sync_mode]
      )
      record.save!
      record
    end

    def newer_thread_update_exists?(user_id:, thread_id:, incoming_sent_at:)
      return false if user_id.blank? || thread_id.blank? || incoming_sent_at.blank?

      where(user_id: user_id, source_thread_id: thread_id)
        .where.not(source_sent_at: nil)
        .where('source_sent_at > ?', incoming_sent_at)
        .exists?
    end

    def replace_thread_records!(user_id:, thread_id:, incoming_sent_at:, leave_dates:)
      return if user_id.blank? || thread_id.blank?

      scope = confirmed.where(user_id: user_id, source_thread_id: thread_id)
      if incoming_sent_at.present?
        scope = scope.where('source_sent_at IS NULL OR source_sent_at <= ?', incoming_sent_at)
      end

      if leave_dates.present?
        scope.where.not(leave_date: leave_dates).delete_all
      else
        scope.delete_all
      end
    end

    def cancel_thread_records!(user_id:, thread_id:, incoming_sent_at:, leave_dates:)
      return if user_id.blank? || thread_id.blank?

      scope = confirmed.where(user_id: user_id, source_thread_id: thread_id)
      if incoming_sent_at.present?
        scope = scope.where('source_sent_at IS NULL OR source_sent_at <= ?', incoming_sent_at)
      end

      if leave_dates.present?
        scope.where(leave_date: leave_dates).delete_all
      else
        scope.delete_all
      end
    end

    def cancel_user_dates!(user_id:, leave_dates:)
      return if user_id.blank? || leave_dates.blank?

      confirmed.where(user_id: user_id, leave_date: leave_dates).delete_all
    end

    def total_leave_days_for_user(user_id:, from_date:, to_date:)
      total_leave_days_for_users(user_ids: [user_id], from_date: from_date, to_date: to_date)[user_id].to_f
    end

    def total_leave_days_for_users(user_ids:, from_date:, to_date:)
      totals = Hash.new(0.0)
      return totals if user_ids.blank?

      confirmed.where(user_id: user_ids).within_range(from_date, to_date).find_each do |record|
        next unless RedmineTimeAnalytics::WorkingDaysCalculator.working_day?(record.leave_date)

        totals[record.user_id] += record.leave_fraction.to_f
      end
      totals
    end

    def sum_for_users_in_period(user_ids:, from_date:, to_date:)
      total_leave_days_for_users(
        user_ids: user_ids,
        from_date: from_date,
        to_date: to_date
      ).values.sum
    end

    def find_active_user_by_sender(sender_value)
      extracted_email = extract_email(sender_value)
      return nil if extracted_email.blank?

      normalized_sender = normalize_lookup_email(extracted_email)
      return nil if normalized_sender.blank?

      User.active.sorted.find do |user|
        normalize_lookup_email(user_email(user)) == normalized_sender
      end
    end

    def extract_email(value)
      email = value.to_s.downcase.scan(/[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}/i).first.to_s.downcase
      email.presence || value.to_s.strip.downcase[0, 255]
    end

    def normalize_lookup_email(value)
      email = extract_email(value)
      return '' unless email.include?('@')

      local_part, domain = email.split('@', 2)
      return '' if local_part.blank? || domain.blank?

      normalized_local = local_part.split('+', 2).first
      normalized_domain = domain
      if %w[gmail.com googlemail.com].include?(normalized_domain)
        normalized_local = normalized_local.delete('.')
        normalized_domain = 'gmail.com'
      end

      "#{normalized_local}@#{normalized_domain}"
    end

    def user_email(user)
      if user.respond_to?(:mail) && user.mail.present?
        user.mail
      else
        user.respond_to?(:email) ? user.email : nil
      end
    end
  end

  def confirmed?
    status == 'confirmed'
  end
end
