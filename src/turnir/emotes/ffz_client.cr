require "http/client"
require "json"
require "./types"

module Turnir::Emotes
  # FFZ API client for fetching global and channel emotes
  # API docs: https://api.betterttv.net/3 (FFZ uses BTTV API)
  class FFZClient
    BASE_URL    = "https://api.betterttv.net/3"
    CDN_BASE    = "https://cdn.betterttv.net/frankerfacez_emote"

    def initialize(@timeout : Time::Span = 10.seconds)
    end

    # Fetch global FFZ emotes
    def get_global_emotes : EmoteSet
      url = "#{BASE_URL}/cached/frankerfacez/emotes/global"
      
      begin
        client = HTTP::Client.new(URI.parse(url))
        client.read_timeout = @timeout
        response = client.get(URI.parse(url).request_target)
        
        if response.status_code != 200
          puts "Failed to fetch FFZ global emotes: #{response.status_code}"
          return EmoteSet.new(Provider::FFZGlobal)
        end

        data = JSON.parse(response.body)
        emotes = parse_emotes(data, Provider::FFZGlobal)
        
        puts "Loaded #{emotes.size} global FFZ emotes"
        EmoteSet.new(Provider::FFZGlobal, emotes)
      rescue ex
        puts "Error fetching FFZ global emotes: #{ex}"
        EmoteSet.new(Provider::FFZGlobal)
      end
    end

    # Fetch channel-specific FFZ emotes
    def get_channel_emotes(channel_id : String) : EmoteSet
      url = "#{BASE_URL}/cached/frankerfacez/users/twitch/#{channel_id}"
      
      begin
        client = HTTP::Client.new(URI.parse(url))
        client.read_timeout = @timeout
        response = client.get(URI.parse(url).request_target)
        
        if response.status_code != 200
          puts "Failed to fetch FFZ channel emotes for #{channel_id}: #{response.status_code}"
          return EmoteSet.new(Provider::FFZChannel, channel: channel_id)
        end

        data = JSON.parse(response.body)
        emotes = parse_emotes(data, Provider::FFZChannel)
        
        puts "Loaded #{emotes.size} channel FFZ emotes for #{channel_id}"
        EmoteSet.new(Provider::FFZChannel, emotes, channel_id)
      rescue ex
        puts "Error fetching FFZ channel emotes for #{channel_id}: #{ex}"
        EmoteSet.new(Provider::FFZChannel, channel: channel_id)
      end
    end

    private def parse_emotes(data : JSON::Any, provider : Provider) : Hash(String, Emote)
      emotes = {} of String => Emote
      
      return emotes unless data.as_a?
      
      data.as_a.each do |emote_data|
        emote_id = emote_data["id"]?.try(&.as_i)
        code = emote_data["code"]?.try(&.as_s)
        
        next unless emote_id && code

        animated = emote_data["animated"]?.try(&.as_bool) || false
        images = emote_data["images"]?
        
        emote_url = create_emote_url(emote_id, images)

        emotes[code] = Emote.new(
          code: code,
          url: emote_url,
          provider: provider,
          is_zero_width: false,
          animated: animated
        )
      end

      emotes
    end

    private def create_emote_url(emote_id : Int32, images : JSON::Any?) : String
      # FFZ provides images object with 1x, 2x, 4x URLs
      # Prefer 2x, fallback to 1x, then 4x
      if images
        url_2x = images["2x"]?.try(&.as_s)
        return url_2x if url_2x && !url_2x.empty?
        
        url_1x = images["1x"]?.try(&.as_s)
        return url_1x if url_1x && !url_1x.empty?
        
        url_4x = images["4x"]?.try(&.as_s)
        return url_4x if url_4x && !url_4x.empty?
      end
      
      # Fallback: construct URL manually
      "#{CDN_BASE}/#{emote_id}/2"
    end

    # Update and save global FFZ emotes to database
    def update_and_save_global_emotes(platform : String = "twitch") : Int32
      begin
        emote_set = get_global_emotes
        return save_emote_set(emote_set, platform, nil)
      rescue ex
        puts "Failed to update FFZ global emotes: #{ex}"
        return 0
      end
    end

    # Update and save channel FFZ emotes to database
    def update_and_save_channel_emotes(channel_id : String, user_slug : String, platform : String = "twitch") : Int32
      begin
        emote_set = get_channel_emotes(channel_id)
        return save_emote_set(emote_set, platform, user_slug)
      rescue ex
        puts "Failed to update FFZ channel emotes for #{channel_id}: #{ex}"
        return 0
      end
    end

    # Save emote set to memory
    private def save_emote_set(emote_set : EmoteSet, platform : String, user_slug : String?) : Int32
      return 0 if emote_set.emotes.empty?

      provider_str = "ffz"
      
      # Store emotes in memory
      # Don't use channel_id in key for channel-specific emotes, user_slug is enough
      Emotes.store_emotes(platform, provider_str, nil, user_slug, emote_set.emotes)
      
      emote_set.emotes.size
    end
  end
end

