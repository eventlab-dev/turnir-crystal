require "http/client"
require "json"
require "./types"

module Turnir::Emotes
  # Twitch Helix API client for utility functions (user ID resolution)
  # Note: Twitch emotes are now extracted from IRC messages, not loaded via API
  class TwitchEmoteClient
    BASE_URL = "https://api.twitch.tv/helix"

    def initialize(
      @client_id : String,
      @access_token : String,
      @timeout : Time::Span = 10.seconds
    )
    end

    # Get Twitch user IDs from login names
    def get_user_ids_batch(logins : Array(String)) : Hash(String, String)
      return {} of String => String if @client_id.empty? || @access_token.empty?
      return {} of String => String if logins.empty?

      # Twitch API allows up to 100 logins per request
      result = {} of String => String
      
      logins.each_slice(100) do |batch|
        login_params = batch.map { |login| "login=#{URI.encode_www_form(login)}" }.join("&")
        url = "#{BASE_URL}/users?#{login_params}"
        headers = build_headers
        
        begin
          uri = URI.parse(url)
          client = HTTP::Client.new(uri)
          client.read_timeout = @timeout
          response = client.get(uri.request_target, headers: headers)
          
          if response.status_code == 200
            data = JSON.parse(response.body)
            users = data["data"]?.try(&.as_a)
            
            users.try(&.each do |user|
              login = user["login"]?.try(&.as_s)
              id = user["id"]?.try(&.as_s)
              result[login.downcase] = id if login && id
            end)
          else
            puts "Failed to fetch Twitch user IDs: #{response.status_code}"
          end
        rescue ex
          puts "Error fetching Twitch user IDs: #{ex}"
        end
      end

      result
    end

    private def build_headers : HTTP::Headers
      headers = HTTP::Headers.new
      headers["Client-Id"] = @client_id
      headers["Authorization"] = "Bearer #{@access_token}"
      headers
    end
  end
end

