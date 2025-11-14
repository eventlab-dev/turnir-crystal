require "http/client"
require "json"
require "./types"

module Turnir::Emotes
  # 7TV API client for fetching global and channel emotes
  # API docs: https://7tv.io/docs
  class SevenTVClient
    BASE_URL    = "https://7tv.io/v3"
    CDN_BASE    = "https://cdn.7tv.app/emote"
    OVERLAY_FLAG = 256 # Flag for zero-width (overlay) emotes

    def initialize(@timeout : Time::Span = 10.seconds)
    end

    # Fetch global 7TV emotes
    def get_global_emotes : EmoteSet
      url = "#{BASE_URL}/emote-sets/global"
      
      begin
        client = HTTP::Client.new(URI.parse(url))
        client.read_timeout = @timeout
        response = client.get(URI.parse(url).request_target)
        
        if response.status_code != 200
          puts "Failed to fetch 7TV global emotes: #{response.status_code}"
          return EmoteSet.new(Provider::SevenTV)
        end

        data = JSON.parse(response.body)
        emotes = parse_emotes(data)
        
        puts "Loaded #{emotes.size} global 7TV emotes"
        EmoteSet.new(Provider::SevenTV, emotes)
      rescue ex
        puts "Error fetching 7TV global emotes: #{ex}"
        EmoteSet.new(Provider::SevenTV)
      end
    end

    # Fetch channel-specific 7TV emotes
    def get_channel_emotes(channel_id : String) : EmoteSet
      url = "#{BASE_URL}/users/twitch/#{channel_id}"
      
      begin
        client = HTTP::Client.new(URI.parse(url))
        client.read_timeout = @timeout
        response = client.get(URI.parse(url).request_target)
        
        if response.status_code != 200
          puts "Failed to fetch 7TV channel emotes for #{channel_id}: #{response.status_code}"
          return EmoteSet.new(Provider::SevenTV, channel: channel_id)
        end

        data = JSON.parse(response.body)
        emote_set = data["emote_set"]?
        
        unless emote_set
          puts "No 7TV emote set found for channel #{channel_id}"
          return EmoteSet.new(Provider::SevenTV, channel: channel_id)
        end

        emotes = parse_emotes(emote_set)
        
        puts "Loaded #{emotes.size} channel 7TV emotes for #{channel_id}"
        EmoteSet.new(Provider::SevenTV, emotes, channel_id)
      rescue ex
        puts "Error fetching 7TV channel emotes for #{channel_id}: #{ex}"
        EmoteSet.new(Provider::SevenTV, channel: channel_id)
      end
    end

    private def parse_emotes(data : JSON::Any) : Hash(String, Emote)
      emotes = {} of String => Emote
      
      emotes_array = data["emotes"]?
      return emotes unless emotes_array

      emotes_array.as_a.each do |emote_data|
        emote_id = emote_data["id"]?.try(&.as_s)
        code = emote_data["name"]?.try(&.as_s)
        
        next unless emote_id && code

        data_obj = emote_data["data"]?
        next unless data_obj

        flags = data_obj["flags"]?.try(&.as_i)
        animated = data_obj["animated"]?.try(&.as_bool) || false
        host = data_obj["host"]?
        host_url = host.try(&.["url"]?).try(&.as_s)

        emote_url = create_emote_url(emote_id, host_url)
        is_overlay = is_overlay_emote(flags)

        emotes[code] = Emote.new(
          code: code,
          url: emote_url,
          provider: Provider::SevenTV,
          is_zero_width: is_overlay,
          animated: animated
        )
      end

      emotes
    end

    private def is_overlay_emote(flags : Int32?) : Bool
      return false unless flags
      (flags & OVERLAY_FLAG) != 0
    end

    private def create_emote_url(emote_id : String, host_url : String?) : String
      if host_url
        host_url = "https:#{host_url}" if host_url.starts_with?("//")
        return "#{host_url}/2x.webp"
      end
      
      "#{CDN_BASE}/#{emote_id}/2x.webp"
    end

    # Update and save global 7TV emotes to database
    def update_and_save_global_emotes(platform : String = "twitch") : Int32
      begin
        emote_set = get_global_emotes
        return save_emote_set(emote_set, platform, nil)
      rescue ex
        puts "Failed to update 7TV global emotes: #{ex}"
        return 0
      end
    end

    # Update and save channel 7TV emotes to database
    def update_and_save_channel_emotes(channel_id : String, user_slug : String, platform : String = "twitch") : Int32
      begin
        emote_set = get_channel_emotes(channel_id)
        return save_emote_set(emote_set, platform, user_slug)
      rescue ex
        puts "Failed to update 7TV channel emotes for #{channel_id}: #{ex}"
        return 0
      end
    end

    # Save emote set to memory
    private def save_emote_set(emote_set : EmoteSet, platform : String, user_slug : String?) : Int32
      return 0 if emote_set.emotes.empty?

      provider_str = "7tv"
      
      # Store emotes in memory
      # Don't use channel_id in key for channel-specific emotes, user_slug is enough
      Emotes.store_emotes(platform, provider_str, nil, user_slug, emote_set.emotes)
      
      emote_set.emotes.size
    end
  end
end

