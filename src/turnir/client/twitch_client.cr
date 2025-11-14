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

    if privmsg_index == 1
      user_part = parts[0]
      channel = parts[2].downcase
      message = parts[3..-1].join(" ").strip
    elsif privmsg_index == 2
      badges_part = parts[0]
      user_part = parts[1]
      channel = parts[3].downcase
      message = parts[4..-1].join(" ").strip
    end

    if user_part.nil? || message.nil? || channel.nil?
      return nil
    end

    if message.size > 0 && message[0] == ':'
      message = message[1..-1]
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
    
    # Parse emotes in the message
    parsed_message = Turnir::Emotes::Parser.parse_twitch_message(message, user_slug)

    Turnir::ChatStorage::Types::ChatMessage.new(id: message_id.to_s, ts: ts, message: parsed_message, user: user, channel: formatted_channel)
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
