# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'

module RedmineTimeAnalytics
  class ExternalRedmineTimeService
    Result = Struct.new(:hours_by_period, :errors, keyword_init: true)

    def initialize(base_url:, api_key:)
      @base_url = base_url.to_s.strip.sub(%r{/\z}, '')
      @api_key = api_key.to_s.strip
    end

    def configured?
      @base_url.present? && @api_key.present?
    end

    def calculate_hours_by_period(assignments:, from:, to:, grouping:)
      return Result.new(hours_by_period: {}, errors: ['Support Redmine integration is not configured']) unless configured?
      return Result.new(hours_by_period: {}, errors: []) if assignments.blank?

      hours_by_period = Hash.new(0.0)
      errors = []

      assignments.group_by(&:external_project_identifier).each do |identifier, project_assignments|
        if identifier.blank?
          errors << 'External project identifier is missing for one or more assignments'
          next
        end

        begin
          entries = TaExternalTimeCache.fetch_or_store(base_url: @base_url, identifier: identifier, from: from, to: to) do
            fetch_entries(project_identifier: identifier, from: from, to: to)
          end
          accumulate_entries(hours_by_period, entries, project_assignments, grouping)
        rescue StandardError => e
          errors << "Failed to fetch external project #{identifier}: #{e.message}"
        end
      end

      Result.new(hours_by_period: hours_by_period, errors: errors)
    end

    # Fetches and normalizes time entries for a single external project + range.
    # Returns a compact, JSON/cache-friendly array of string-keyed hashes so the result can be
    # cached in TaExternalTimeCache and replayed through #accumulate_entries unchanged.
    def fetch_entries(project_identifier:, from:, to:)
      fetch_time_entries(project_identifier: project_identifier, from: from, to: to).map do |entry|
        { 'spent_on' => entry['spent_on'].to_s, 'hours' => entry['hours'].to_f }
      end
    end

    private

    def fetch_time_entries(project_identifier:, from:, to:)
      offset = 0
      limit = 100
      all_entries = []

      loop do
        uri = URI.parse("#{@base_url}/time_entries.json")
        query = {
          project_id: project_identifier,
          from: from.strftime('%Y-%m-%d'),
          to: to.strftime('%Y-%m-%d'),
          limit: limit,
          offset: offset
        }
        uri.query = URI.encode_www_form(query)

        request = Net::HTTP::Get.new(uri)
        request['X-Redmine-API-Key'] = @api_key
        request['Content-Type'] = 'application/json'

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') do |http|
          http.request(request)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise "HTTP #{response.code}"
        end

        body = JSON.parse(response.body)
        entries = body['time_entries'] || []
        all_entries.concat(entries)

        total_count = body['total_count'].to_i
        offset += entries.length
        break if entries.empty? || offset >= total_count
      end

      all_entries
    end

    def accumulate_entries(hours_by_period, entries, assignments, grouping)
      entries.each do |entry|
        spent_on = Date.parse(entry['spent_on'].to_s)
        hours = entry['hours'].to_f
        next if hours.zero?

        active_assignment = assignments.any? { |assignment| assignment.active_on?(spent_on) }
        next unless active_assignment

        key = period_key_for_date(spent_on, grouping)
        hours_by_period[key] += hours
      end
    end

    def period_key_for_date(date, grouping)
      case grouping
      when 'daily'
        date
      when 'monthly'
        [date.year, date.month]
      else
        date.beginning_of_week(:monday)
      end
    end
  end
end
