require "http/client"
require "json"

module Turnir::Emotes
  # Emote provider types
  enum Provider
    SevenTV
    TwitchGlobal
    TwitchChannel
    BTTVGlobal
    BTTVChannel
    FFZGlobal
    FFZChannel
  end

  # Single emote data
  struct Emote
    property code : String
    property url : String
    property provider : Provider
    property is_zero_width : Bool
    property animated : Bool

    def initialize(
      @code : String,
      @url : String,
      @provider : Provider,
      @is_zero_width : Bool = false,
      @animated : Bool = false
    )
    end
  end

  # Collection of emotes from a provider
  struct EmoteSet
    property provider : Provider
    property emotes : Hash(String, Emote)
    property channel : String?

    def initialize(
      @provider : Provider,
      @emotes : Hash(String, Emote) = {} of String => Emote,
      @channel : String? = nil
    )
    end
  end

  # In-memory storage for all emotes
  # Structure: { "platform:provider:channel_id:user_slug" => { "emote_code" => Emote } }
  @@emotes_storage = Hash(String, Hash(String, Emote)).new
  @@storage_lock = Mutex.new

  # Get emotes for specific context
  def self.get_emotes(platform : String, user_slug : String?) : Hash(String, Emote)
    result = Hash(String, Emote).new
    
    @@storage_lock.synchronize do
      # Priority order: 7TV channel > 7TV global > BTTV channel > BTTV global > FFZ channel > FFZ global > Twitch channel > Twitch global
      providers = [
        {"7tv", user_slug},
        {"7tv", nil},
        {"bttv", user_slug},
        {"bttv", nil},
        {"ffz", user_slug},
        {"ffz", nil},
        {"twitch_channel", user_slug},
        {"twitch_channel", nil},
        {"twitch_global", nil},
      ]

      providers.each do |(provider, slug)|
        key = make_storage_key(platform, provider, nil, slug)
        if @@emotes_storage.has_key?(key)
          emotes_found = @@emotes_storage[key]
          
          emotes_found.each do |code, emote|
            # Only add if not already present (first one wins)
            result[code] = emote unless result.has_key?(code)
          end
        end
      end

    end

    result
  end

  # Store emotes for a specific context
  def self.store_emotes(platform : String, provider : String, channel_id : String?, user_slug : String?, emotes : Hash(String, Emote))
    key = make_storage_key(platform, provider, channel_id, user_slug)
    
    @@storage_lock.synchronize do
      @@emotes_storage[key] = emotes
      emote_codes = emotes.keys.first(5).join(", ")
      more = emotes.size > 5 ? " and #{emotes.size - 5} more" : ""
      puts "Stored #{emotes.size} emotes for #{key}"
      puts " Examples: #{emote_codes}#{more}"
    end
  end

  # Clear emotes for specific context
  def self.clear_emotes(platform : String, provider : String, channel_id : String?, user_slug : String?)
    key = make_storage_key(platform, provider, channel_id, user_slug)
    
    @@storage_lock.synchronize do
      @@emotes_storage.delete(key)
    end
  end

  # Clear all emotes
  def self.clear_all_emotes
    @@storage_lock.synchronize do
      @@emotes_storage.clear
      puts "Cleared all emotes from memory"
    end
  end

  # Get storage statistics
  def self.get_stats : Hash(String, Int32)
    @@storage_lock.synchronize do
      total_emotes = @@emotes_storage.values.sum(&.size)
      {
        "storage_keys" => @@emotes_storage.size,
        "total_emotes" => total_emotes,
      }
    end
  end

  # Get debug info about storage (for debugging)
  def self.get_debug_info : Array(String)
    @@storage_lock.synchronize do
      @@emotes_storage.map do |key, emotes|
        examples = emotes.keys.first(3).join(", ")
        "#{key} (#{emotes.size} emotes: #{examples}...)"
      end.to_a
    end
  end

  private def self.make_storage_key(platform : String, provider : String, channel_id : String?, user_slug : String?) : String
    "#{platform}:#{provider}:#{channel_id || "global"}:#{user_slug || "global"}"
  end
end

