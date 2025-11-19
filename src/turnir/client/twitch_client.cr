require "http/client"
require "time"
require "../chat_storage/types"
require "../chat_storage/storage"
require "../config"
require "../emotes/parser"

module Turnir::Client::TwitchWebsocket
  extend self

  @@websocket : HTTP::WebSocket | Nil = nil
  WebsocketMutex = Mutex.new

  @@message_counter = 0
  @@channels_map = {} of String => String
  @@reverse_channels_map = {} of String => String

  @@global_badges_map = {} of String => Hash(String, Turnir::Parser::Twitch::BadgeVersion)
  @@channel_badges_map = {} of String => Hash(String, Hash(String, Turnir::Parser::Twitch::BadgeVersion))
  @@broadcasters_map = {} of String => String

  def log(msg)
    print "[TwitchWS] "
    puts msg
  end

  def start(sync_channel : Channel(Nil), storage : Turnir::ChatStorage::Storage, channels_map : Hash(String, String))
    @@channels_map = channels_map
    @@reverse_channels_map = @@channels_map.invert

    log "Starting Twitch client"

    WebsocketMutex.synchronize do
      if @@websocket.nil?
        @@websocket = HTTP::WebSocket.new(
          "wss://irc-ws.chat.twitch.tv:443",
          headers = HTTP::Headers{
            "Origin" => "https://www.twitch.tv",
          },
        )
      end
    end

    websocket = @@websocket
    if websocket.nil?
      log "Failed to start websocket"
      sync_channel.send(nil)  # Unblock the main thread
      return
    end

    websocket.on_message do |msg|
      # Отвечаем на PING от сервера
      if msg == "PING :tmi.twitch.tv"
        websocket.send("PONG :tmi.twitch.tv")
        next
      end
      if msg.starts_with?("PONG") || msg.starts_with?(":tmi.twitch.tv PONG")
        #log "Received PONG from server"
        next
      end
      
      #log "IRC RAW: #{msg}"
      
      if msg.includes?(":tmi.twitch.tv NOTICE * :Login authentication failed") || 
         msg.includes?(":tmi.twitch.tv NOTICE * :Improperly formatted auth")
        log "ERROR: Twitch authentication failed! Token may be invalid or not suitable for IRC."
        log "Tip: Use User Access Token (with chat:read scope) instead of App Access Token"
      end
      
      if msg.includes?(" 001 ")
        log "Successfully connected to Twitch IRC!"
      end
      
      parsed = parse_message(msg)
      if parsed
        storage.add_message(parsed)
      end
    end

    websocket.on_close do |code|
      log "Websocket Closed: #{code}"
      Turnir::Client.disconnect_streams_for_client(Turnir::Client::ClientType::TWITCH)
      @@websocket = nil
    end

    @@global_badges_map = fetch_badges()
    log "Global badges fetched: #{@@global_badges_map.size}"

    nick = "justinfan#{rand(100000..999999)}"
    log "Using anonymous IRC connection (read-only) with NICK: #{nick}"
    websocket.send("PASS SCHMOOPIIE")
    websocket.send("NICK #{nick}")
    
    log "Requesting IRC capabilities..."
    websocket.send("CAP REQ :twitch.tv/tags twitch.tv/commands")
    
    spawn do
      loop do
        sleep 4.minutes
        if websocket.closed?
          log "Websocket closed, exiting keepalive..."
          break
        end
        begin
          websocket.send("PING :tmi.twitch.tv")
          log "Sent keepalive PING"
        rescue ex
          log "Keepalive PING error: #{ex.inspect}"
          break
        end
      end
    end
    
    sync_channel.send(nil)
    websocket.run
    @@websocket = nil
  end

  def subscribe_to_channel(channel_name : String)
    websocket = @@websocket
    if websocket.nil?
      log "Websocket is not connected"
      return
    end

    internal_channel = "##{channel_name.downcase}"
    formatted_channel = "twitch/#{channel_name.downcase}"
    @@channels_map[channel_name] = formatted_channel
    @@reverse_channels_map[internal_channel] = channel_name

    if @@channel_badges_map.fetch(internal_channel, nil).nil?
      @@channel_badges_map[internal_channel] = fetch_badges(channel_name)
      log "Channel #{channel_name} badges fetched: #{@@channel_badges_map[internal_channel].size}"
    end

    log "Sending JOIN command for channel: #{channel_name}"
    websocket.send("JOIN ##{channel_name}")
  end

  def stop
    @@websocket.try { |ws| ws.close }
  end

  def get_websocket_status : String
    ws = @@websocket
    if ws.nil?
      return "not_connected"
    end
    if ws.closed?
      return "closed"
    end
    "connected"
  end

  def parse_message(msg : String) : Turnir::ChatStorage::Types::ChatMessage | Nil
    parts = msg.split(/\s+/)

    if parts[1] == "JOIN" && parts.size > 2
      channel_name = @@reverse_channels_map.fetch(parts[2], nil)
      if channel_name
        Turnir::Client.on_subscribe(
          Turnir::Client::ClientType::TWITCH,
          channel_name,
        )
      end
    end

    if parts.size < 4
      return nil
    end

    # find id of PRIVMSG
    privmsg_index = parts.index("PRIVMSG")

    user_part = nil
    badges_part = ""
    message = nil
    channel = nil

    # Extract message preserving original spacing (important for emote position parsing)
    # Find PRIVMSG and extract everything after the channel name
    if privmsg_index
      # Find the position of PRIVMSG in the original message
      privmsg_pos = msg.index("PRIVMSG")
      return nil unless privmsg_pos
      
      # Find the channel name after PRIVMSG
      after_privmsg = msg[privmsg_pos + 7..-1]  # Skip "PRIVMSG"
      after_privmsg = after_privmsg.lstrip
      
      # Find the channel (starts with #)
      channel_start = after_privmsg.index("#")
      return nil unless channel_start
      
      after_channel_start = after_privmsg[channel_start..-1]
      # Find where channel name ends (space or end)
      channel_end = after_channel_start.index(/\s+/)
      if channel_end
        channel_part = after_channel_start[0...channel_end]
        message_part = after_channel_start[channel_end..-1].lstrip
      else
        channel_part = after_channel_start
        message_part = ""
      end
      
      channel = channel_part.downcase
      
      # Extract message (everything after channel, remove leading colon if present)
      if message_part.size > 0 && message_part[0] == ':'
        message = message_part[1..-1]
      else
        message = message_part
      end
      
      # Extract user parts and badges
      if privmsg_index == 1
        user_part = parts[0]
        badges_part = ""
      elsif privmsg_index == 2
        badges_part = parts[0]
        user_part = parts[1]
      end
    end

    if user_part.nil? || message.nil? || channel.nil?
      return nil
    end

    ts = Time.utc.to_unix_ms

    @@message_counter += 1
    message_id = @@message_counter

    user_info = parse_badges(channel, badges_part)

    user_name = user_part.split("!")[0][1..-1]
    user = Turnir::ChatStorage::Types::ChatUser.new(
      id: user_name,
      username: user_info.display_name || user_name,
      twitch_fields: user_info
    )

    # log "Parsed message: #{channel} #{user.username}: #{message}"
    
    channel_name = channel.starts_with?("#") ? channel[1..-1] : channel
    formatted_channel = "twitch/#{channel_name}"
    
    # Get user_slug for this channel from channels_map
    # channels_map contains "twitch/username" format, but emotes storage uses just "username"
    user_slug_with_prefix = @@channels_map.fetch(channel_name, nil)
    user_slug = user_slug_with_prefix ? user_slug_with_prefix.sub("twitch/", "") : nil
    
    # Extract Twitch emotes from IRC tags
    irc_emotes = parse_irc_emotes(badges_part, message)
    
    # Parse emotes in the message (Twitch emotes from IRC + 7TV/BTTV/FFZ from memory)
    parsed_message = Turnir::Emotes::Parser.parse_twitch_message(message, user_slug, irc_emotes)

    Turnir::ChatStorage::Types::ChatMessage.new(id: message_id.to_s, ts: ts, message: parsed_message, user: user, channel: formatted_channel)
  end

  def parse_irc_emotes(badges_str : String, message : String) : Hash(String, String)
    irc_emotes = Hash(String, String).new
    
    return irc_emotes if badges_str.empty?
    
    # Extract emotes= field from IRC tags
    # Format: emotes=emote_id:start-end/emote_id:start-end
    parts = badges_str.split(";")
    emotes_str = nil
    
    parts.each do |part|
      if part.starts_with?("emotes=")
        emotes_str = part.split("=")[1]
        break
      end
    end
    
    return irc_emotes unless emotes_str && !emotes_str.empty?
    
    # Parse emote positions: emote_id:start-end/emote_id:start-end
    # Multiple ranges for same emote_id are separated by commas: emote_id:start1-end1,start2-end2
    emotes_str.split("/").each do |emote_data|
      # Split emote_id and positions
      colon_index = emote_data.index(":")
      next unless colon_index
      
      emote_id = emote_data[0...colon_index]
      positions_str = emote_data[colon_index + 1..-1]
      
      # Parse all position ranges for this emote (comma-separated)
      positions_str.split(",").each do |position|
        # Parse start-end
        dash_index = position.index("-")
        next unless dash_index
        
        start_pos = position[0...dash_index].to_i? || 0
        end_pos = position[dash_index + 1..-1].to_i? || 0
        next if start_pos < 0 || end_pos < start_pos
        
        # Extract emote text from message using byte positions
        # Twitch IRC uses byte positions, not character positions
        # Positions are inclusive (start-end means bytes from start to end, both inclusive)
        message_bytes = message.to_slice
        if start_pos >= 0 && end_pos >= start_pos && end_pos < message_bytes.size
          emote_bytes = message_bytes[start_pos..end_pos]
          emote_code = String.new(emote_bytes)
          
          # Store emote_id -> emote_code mapping (only first occurrence, or we could merge)
          if !irc_emotes.has_key?(emote_id)
            irc_emotes[emote_id] = emote_code
            #log "Parsed IRC emote: #{emote_id} -> '#{emote_code}' (positions #{start_pos}-#{end_pos})"
          end
        else
          log "Warning: Invalid emote positions #{start_pos}-#{end_pos} for message size #{message_bytes.size}"
        end
      end
    end
    
    irc_emotes
  end

  def parse_badges(channel_name : String, badges_str : String) : Turnir::Parser::Twitch::UserInfo
    parts = badges_str.split(";")

    badges = [] of Turnir::Parser::Twitch::BadgeVersion
    color = nil
    display_name = nil

    # log "parsincg badges: #{badges_str}"

    parts.each do |part|
      if part.starts_with?("badges=")
        items = part.split("=")[1].split(",")
        items.each do |item|
          item_parts = item.split("/")
          if item_parts.size == 2
            badge = get_global_badge(item_parts[0], item_parts[1])
            if badge.nil?
              badge = get_channel_badge(channel_name, item_parts[0], item_parts[1])
            end
            if badge.nil?
              next
            end
            badges.push(badge)
          end
        end
      elsif part.starts_with?("color=")
        color = part.split("=")[1]
      elsif part.starts_with?("display-name=")
        display_name = part.split("=")[1]
      end
    end

    Turnir::Parser::Twitch::UserInfo.new(
      badges: badges,
      color: color,
      display_name: display_name
    )
  end

  def get_global_badge(badge_name : String, version_id : String)
    @@global_badges_map.fetch(
      badge_name,
      {} of String => Turnir::Parser::Twitch::BadgeVersion
    ).fetch(version_id, nil)
  end

  def get_channel_badge(channel_name : String, badge_name : String, version_id : String)
    @@channel_badges_map.fetch(
      channel_name,
      {} of String => Hash(String, Turnir::Parser::Twitch::BadgeVersion)
    ).fetch(
      badge_name,
      {} of String => Turnir::Parser::Twitch::BadgeVersion
    ).fetch(version_id, nil)
  end

  def get_broadcaster_id(channel_name : String) : String | Nil
    id = @@broadcasters_map.fetch(channel_name, nil)
    if id.nil?
      id = fetch_broadcaster_id(channel_name)
      if id
        @@broadcasters_map[channel_name] = id
      end
    end
    id
  end

  def fetch_broadcaster_id(channel_name : String) : String | Nil
    response = HTTP::Client.get("https://api.twitch.tv/helix/users?login=#{channel_name}", headers: auth_headers)
    begin
      parsed = Turnir::Parser::Twitch::BroadcasterResponse.from_json(response.body)
      if parsed.data.size == 0
        return nil
      end
      parsed.data[0].id
    rescue ex : JSON::Error
      log "Failed to parse broadcaster id: #{ex.inspect}"
      nil
    end
  end

  def fetch_badges(channel_name : String | Nil = nil)
    result = {} of String => Hash(String, Turnir::Parser::Twitch::BadgeVersion)

    url = "https://api.twitch.tv/helix/chat/badges/global"
    if channel_name
      broadcaster_id = get_broadcaster_id(channel_name)
      if broadcaster_id != nil
        url = "https://api.twitch.tv/helix/chat/badges?broadcaster_id=#{broadcaster_id}"
      end
    end

    response = HTTP::Client.get(url, headers: auth_headers)

    begin
      parsed = Turnir::Parser::Twitch::BadgesResponse.from_json(response.body)
      parsed.data.each do |badge_set|
        result[badge_set.set_id] = {} of String => Turnir::Parser::Twitch::BadgeVersion
        badge_set.versions.each do |version|
          result[badge_set.set_id][version.id] = version
        end
      end
    rescue ex : JSON::Error
      log "Failed to parse global badges: #{ex.inspect} #{response.body.inspect}"
    end
    result
  end

  def auth_headers : HTTP::Headers
    HTTP::Headers{
      "Client-ID"     => Turnir::Config::TWITCH_CLIENT_ID,
      "Authorization" => "Bearer #{Turnir::Config.get_twitch_token}",
    }
  end
end
