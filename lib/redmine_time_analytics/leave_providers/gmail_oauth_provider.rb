# frozen_string_literal: true

module RedmineTimeAnalytics
  module LeaveProviders
    class GmailOauthProvider < GmailBaseProvider
      private

      def authorization
        client_id = settings[:oauth_client_id].to_s.strip
        client_secret = settings[:oauth_client_secret].to_s
        refresh_token = settings[:oauth_refresh_token].to_s
        if client_id.blank? || client_secret.blank? || refresh_token.blank?
          raise 'OAuth client ID, client secret, and refresh token are required'
        end

        oauth_client = Signet::OAuth2::Client.new(
          token_credential_uri: 'https://oauth2.googleapis.com/token',
          client_id: client_id,
          client_secret: client_secret,
          refresh_token: refresh_token
        )
        oauth_client.fetch_access_token!
        oauth_client
      end
    end
  end
end
