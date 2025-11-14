require "http/client"
require "json"
require "./types"

module Turnir::Emotes
  # Twitch Helix API client for fetching native Twitch emotes
  # API docs: https://dev.twitch.tv/docs/api/reference#get-global-emotes
  class TwitchEmoteClient
    BASE_URL             = "https://api.twitch.tv/helix"
    EMOTE_CDN_TEMPLATE   = "https://static-cdn.jtvnw.net/emoticons/v2/%s/default/dark/2.0"

    def initialize(
      @client_id : String,
      @access_token : String,
      @timeout : Time::Span = 10.seconds
    )
    end

    # Fetch global Twitch emotes
    def get_global_emotes : EmoteSet
      return empty_set(Provider::TwitchGlobal) if @client_id.empty? || @access_token.empty?

      url = "#{BASE_URL}/chat/emotes/global"
      headers = build_headers
      
      begin
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.read_timeout = @timeout
        response = client.get(uri.request_target, headers: headers)
        
        if response.status_code != 200
          puts "Failed to fetch Twitch global emotes: #{response.status_code}"
          return empty_set(Provider::TwitchGlobal)
        end

        data = JSON.parse(response.body)
        emotes = parse_emotes(data, Provider::TwitchGlobal)
        
        puts "Loaded #{emotes.size} global Twitch emotes"
        EmoteSet.new(Provider::TwitchGlobal, emotes)
      rescue ex
        puts "Error fetching Twitch global emotes: #{ex}"
        empty_set(Provider::TwitchGlobal)
      end
    end

    # Fetch channel-specific Twitch emotes
    def get_channel_emotes(broadcaster_id : String) : EmoteSet
      return empty_set(Provider::TwitchChannel, broadcaster_id) if @client_id.empty? || @access_token.empty?

      url = "#{BASE_URL}/chat/emotes?broadcaster_id=#{broadcaster_id}"
      headers = build_headers
      
      begin
        uri = URI.parse(url)
        client = HTTP::Client.new(uri)
        client.read_timeout = @timeout
        response = client.get(uri.request_target, headers: headers)
        
        if response.status_code != 200
          puts "Failed to fetch Twitch channel emotes for #{broadcaster_id}: #{response.status_code}"
          return empty_set(Provider::TwitchChannel, broadcaster_id)
        end

        data = JSON.parse(response.body)
        emotes = parse_emotes(data, Provider::TwitchChannel)
        
        puts "Loaded #{emotes.size} channel Twitch emotes for #{broadcaster_id}"
        EmoteSet.new(Provider::TwitchChannel, emotes, broadcaster_id)
      rescue ex
        puts "Error fetching Twitch channel emotes for #{broadcaster_id}: #{ex}"
        empty_set(Provider::TwitchChannel, broadcaster_id)
      end
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

    private def parse_emotes(data : JSON::Any, provider : Provider) : Hash(String, Emote)
      emotes = {} of String => Emote
      
      emotes_array = data["data"]?
      return emotes unless emotes_array

      emotes_array.as_a.each do |emote_data|
        emote_id = emote_data["id"]?.try(&.as_s)
        code = emote_data["name"]?.try(&.as_s)
        
        next unless emote_id && code

        template = emote_data["template"]?.try(&.as_s)
        emote_url = create_emote_url(emote_id, template)

        emotes[code] = Emote.new(
          code: code,
          url: emote_url,
          provider: provider,
          is_zero_width: false,
          animated: false # Twitch API doesn't expose this directly
        )
      end

      emotes
    end

    private def create_emote_url(emote_id : String, template : String?) : String
      if template
        url = template.gsub("{{id}}", emote_id)
        url = url.gsub("{{format}}", "default")
        url = url.gsub("{{theme_mode}}", "dark")
        url = url.gsub("{{scale}}", "2.0")
        return url
      end
      
      EMOTE_CDN_TEMPLATE % emote_id
    end

    private def empty_set(provider : Provider, channel : String? = nil) : EmoteSet
      EmoteSet.new(provider, {} of String => Emote, channel)
    end

    # Update and save global Twitch emotes to database
    def update_and_save_global_emotes(platform : String = "twitch") : Int32
      begin
        emote_set = get_global_emotes
        return save_emote_set(emote_set, platform, nil)
      rescue ex
        puts "Failed to update Twitch global emotes: #{ex}"
        return 0
      end
    end

    # Update and save channel Twitch emotes to database
    def update_and_save_channel_emotes(channel_id : String, user_slug : String, platform : String = "twitch") : Int32
      begin
        emote_set = get_channel_emotes(channel_id)
        return save_emote_set(emote_set, platform, user_slug)
      rescue ex
        puts "Failed to update Twitch channel emotes for #{channel_id}: #{ex}"
        return 0
      end
    end

    # Save emote set to memory
    private def save_emote_set(emote_set : EmoteSet, platform : String, user_slug : String?) : Int32
      return 0 if emote_set.emotes.empty?

      provider_str = provider_to_string(emote_set.provider)
      
      # Store emotes in memory
      # Don't use channel_id in key for channel-specific emotes, user_slug is enough
      Emotes.store_emotes(platform, provider_str, nil, user_slug, emote_set.emotes)
      
      emote_set.emotes.size
    end

    # Convert provider enum to string
    private def provider_to_string(provider : Provider) : String
      case provider
      when Provider::TwitchGlobal
        "twitch_global"
      when Provider::TwitchChannel
        "twitch_channel"
      else
        "unknown"
      end
    end
  end
end

