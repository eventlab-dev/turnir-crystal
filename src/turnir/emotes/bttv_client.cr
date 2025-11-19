require "http/client"
require "json"
require "./types"

module Turnir::Emotes
  # BTTV API client for fetching global and channel emotes
  # API docs: https://api.betterttv.net/3
  class BTTVClient
    BASE_URL    = "https://api.betterttv.net/3"
    CDN_BASE    = "https://cdn.betterttv.net/emote"

    def initialize(@timeout : Time::Span = 10.seconds)
    end

    # Fetch global BTTV emotes
    def get_global_emotes : EmoteSet
      url = "#{BASE_URL}/cached/emotes/global"
      
      begin
        client = HTTP::Client.new(URI.parse(url))
        client.read_timeout = @timeout
        response = client.get(URI.parse(url).request_target)
        
        if response.status_code != 200
          puts "Failed to fetch BTTV global emotes: #{response.status_code}"
          return EmoteSet.new(Provider::BTTVGlobal)
        end

        data = JSON.parse(response.body)
        emotes = parse_emotes(data, Provider::BTTVGlobal)
        
        puts "Loaded #{emotes.size} global BTTV emotes"
        EmoteSet.new(Provider::BTTVGlobal, emotes)
      rescue ex
        puts "Error fetching BTTV global emotes: #{ex}"
        EmoteSet.new(Provider::BTTVGlobal)
      end
    end

    # Fetch channel-specific BTTV emotes
    def get_channel_emotes(channel_id : String) : EmoteSet
      url = "#{BASE_URL}/cached/users/twitch/#{channel_id}"
      
      begin
        client = HTTP::Client.new(URI.parse(url))
        client.read_timeout = @timeout
        response = client.get(URI.parse(url).request_target)
        
        if response.status_code != 200
          puts "Failed to fetch BTTV channel emotes for #{channel_id}: #{response.status_code}"
          return EmoteSet.new(Provider::BTTVChannel, channel: channel_id)
        end

        data = JSON.parse(response.body)
        
        emotes = {} of String => Emote
        
        # Parse channelEmotes
        channel_emotes = data["channelEmotes"]?
        if channel_emotes
          parsed = parse_emotes_array(channel_emotes.as_a, Provider::BTTVChannel)
          parsed.each { |code, emote| emotes[code] = emote }
        end
        
        # Parse sharedEmotes
        shared_emotes = data["sharedEmotes"]?
        if shared_emotes
          parsed = parse_emotes_array(shared_emotes.as_a, Provider::BTTVChannel)
          parsed.each { |code, emote| emotes[code] = emote }
        end
        
        puts "Loaded #{emotes.size} channel BTTV emotes for #{channel_id}"
        EmoteSet.new(Provider::BTTVChannel, emotes, channel_id)
      rescue ex
        puts "Error fetching BTTV channel emotes for #{channel_id}: #{ex}"
        EmoteSet.new(Provider::BTTVChannel, channel: channel_id)
      end
    end

    private def parse_emotes(data : JSON::Any, provider : Provider) : Hash(String, Emote)
      emotes = {} of String => Emote
      
      return emotes unless data.as_a?
      
      parse_emotes_array(data.as_a, provider).each do |code, emote|
        emotes[code] = emote
      end
      
      emotes
    end

    private def parse_emotes_array(emotes_array : Array(JSON::Any), provider : Provider) : Hash(String, Emote)
      emotes = {} of String => Emote
      
      emotes_array.each do |emote_data|
        emote_id = emote_data["id"]?.try(&.as_s)
        code = emote_data["code"]?.try(&.as_s)
        
        next unless emote_id && code

        animated = emote_data["animated"]?.try(&.as_bool) || false
        image_type = emote_data["imageType"]?.try(&.as_s) || "png"
        
        emote_url = create_emote_url(emote_id, image_type)

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

    private def create_emote_url(emote_id : String, image_type : String) : String
      extension = image_type == "gif" ? "gif" : "webp"
      "#{CDN_BASE}/#{emote_id}/2x.#{extension}"
    end

    # Update and save global BTTV emotes to database
    def update_and_save_global_emotes(platform : String = "twitch") : Int32
      begin
        emote_set = get_global_emotes
        return save_emote_set(emote_set, platform, nil)
      rescue ex
        puts "Failed to update BTTV global emotes: #{ex}"
        return 0
      end
    end

    # Update and save channel BTTV emotes to database
    def update_and_save_channel_emotes(channel_id : String, user_slug : String, platform : String = "twitch") : Int32
      begin
        emote_set = get_channel_emotes(channel_id)
        return save_emote_set(emote_set, platform, user_slug)
      rescue ex
        puts "Failed to update BTTV channel emotes for #{channel_id}: #{ex}"
        return 0
      end
    end

    # Save emote set to memory
    private def save_emote_set(emote_set : EmoteSet, platform : String, user_slug : String?) : Int32
      return 0 if emote_set.emotes.empty?

      provider_str = "bttv"
      
      # Store emotes in memory
      # Don't use channel_id in key for channel-specific emotes, user_slug is enough
      Emotes.store_emotes(platform, provider_str, nil, user_slug, emote_set.emotes)
      
      emote_set.emotes.size
    end
  end
end


