# frozen_string_literal: true

module RedmineTimeAnalytics
  module LeaveProviders
    class GmailDwdProvider < GmailBaseProvider
      private

      def authorization
        credentials_json = settings[:dwd_service_account_json].to_s
        delegated_user = settings[:dwd_delegated_user].to_s.strip
        if credentials_json.blank? || delegated_user.blank?
          raise 'DWD delegated user and service account JSON are required'
        end

        scopes = [Google::Apis::GmailV1::AUTH_GMAIL_READONLY]
        creds = Google::Auth::ServiceAccountCredentials.make_creds(
          json_key_io: StringIO.new(credentials_json),
          scope: scopes
        )
        creds.sub = delegated_user
        creds.fetch_access_token!
        creds
      end
    end
  end
end
