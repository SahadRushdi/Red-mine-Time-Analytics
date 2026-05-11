#!/usr/bin/env ruby
# frozen_string_literal: true

require 'base64'
require 'logger'
require 'ostruct'
require 'active_support'
require 'active_support/core_ext'

require_relative '../lib/redmine_time_analytics/leave_providers/base_provider'
require_relative '../lib/redmine_time_analytics/leave_providers/gmail_base_provider'

provider = RedmineTimeAnalytics::LeaveProviders::GmailBaseProvider.allocate

plain_part = OpenStruct.new(
  mime_type: 'text/plain',
  body: OpenStruct.new(data: Base64.urlsafe_encode64('Please note this will be a full day leave.'))
)
html_part = OpenStruct.new(
  mime_type: 'text/html',
  body: OpenStruct.new(data: Base64.urlsafe_encode64('<div>Please note this leave is shifted to next week(06.02.2026)(evening).</div>'))
)
multi_part = OpenStruct.new(
  mime_type: 'multipart/alternative',
  body: OpenStruct.new(data: nil),
  parts: [html_part]
)

plain = provider.send(:extract_body, plain_part)
html = provider.send(:extract_body, html_part)
multipart = provider.send(:extract_body, multi_part)

raise 'plain text extraction failed' unless plain.include?('full day leave')
raise 'html extraction failed' unless html.include?('06.02.2026')
raise 'multipart extraction failed' unless multipart.include?('06.02.2026')

puts 'Gmail body extraction regression checks passed.'
