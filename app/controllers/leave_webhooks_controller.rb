# frozen_string_literal: true

class LeaveWebhooksController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:google_apps_script]

  def google_apps_script
    render json: { error: 'Google Apps Script webhook support has been removed. Please use Gmail OAuth 2.0 instead.' }, status: :not_found
  end
end
