require "json"
require "xml"
require "http/client"

require "../parser/vk"

module Turnir::Client::VkWebsocket
  extend self

  WS_URL  = "wss://pubsub.live.vkvideo.ru/connection/websocket?cf_protocol_version=v2"
  Headers = HTTP::Headers{"Origin" => "https://live.vkvideo.ru"}

  CHANNEL_INFO_URL = "https://api.live.vkvideo.ru/v1/blog/{{name}}/public_video_stream/chat/user/"

  @@websocket : HTTP::WebSocket | Nil = nil
  WebsocketMutex = Mutex.new

  @@message_counter = 0
  @@channels_map = {} of String => String
  @@reverse_channels_map = {} of String => String
  @@subscriptions_map = {} of Int32 => String

  def log(msg)
    print "[VkvideoWS] "
    puts msg
  end

  def start(sync_channel : Channel(Nil), storage : Turnir::ChatStorage::Storage, channels_map : Hash(String, String))
    app_config = get_vk_app_config()
    if app_config.nil?
      log "Failed to get vk token"
      sync_channel.send(nil)  # Unblock the main thread
      return
    end

    log "Got app config: #{app_config.inspect}"
    @@channels_map = channels_map
    @@reverse_channels_map = channels_map.invert
    @@subscriptions_map = Hash(Int32, String).new

    WebsocketMutex.synchronize do
      if @@websocket.nil?
        @@websocket = HTTP::WebSocket.new(
          WS_URL,
          headers = Headers,
        )
      end
    end

    websocket = @@websocket
    if websocket.nil?
      log "Failed to create websocket"
      sync_channel.send(nil)  # Unblock the main thread
      return
    end

    websocket.on_message do |msg|
      # log "WS message: #{msg}"
      if msg == "{}"
        websocket.send("{}")
        next
      end
      parsed = parse_message(msg)
      if parsed
        storage.add_message(parsed)
      end
    end

    websocket.on_close do |code|
      log "Websocket Closed: #{code}"
      Turnir::Client.disconnect_streams_for_client(Turnir::Client::ClientType::VKVIDEO)
      @@websocket = nil
    end

    log "Starting websocket"
    send_login(app_config.websocket.token)

    sync_channel.send(nil)
    websocket.run
    @@websocket = nil
  end

  def parse_message(json_message)
    begin
      parsed = Turnir::Parser::Vk::ErrorMessage.from_json(json_message)
      if parsed.error.code == 105
        channel_id = @@subscriptions_map.fetch(parsed.id, nil)
        channel_name = @@reverse_channels_map.fetch(channel_id, nil)
        if channel_name
          log "Already subscribed to #{channel_name}"
          Turnir::Client.on_subscribe(
            Turnir::Client::ClientType::VKVIDEO,
            channel_name,
          )
          return nil
        end
      end
    rescue ex
    end

    begin
      parsed = Turnir::Parser::Vk::SubscriptionMessage.from_json(json_message)
      channel_id = @@subscriptions_map.fetch(parsed.id, nil)
      channel_name = @@reverse_channels_map.fetch(channel_id, nil)
      if channel_name
        log "Subscribed to #{channel_name}"
        Turnir::Client.on_subscribe(
          Turnir::Client::ClientType::VKVIDEO,
          channel_name,
        )
        return nil
      end
    rescue ex
    end

    begin
      json_obj = JSON.parse(json_message)
      if json_obj.as_h.has_key?("connect") || json_obj.as_h.has_key?("ping")
        return nil
      end
    rescue ex
    end

    begin
      parsed = Turnir::Parser::Vk::ChatMessage.from_json(json_message)
    rescue ex
      log "Failed to parse message: #{ex.inspect}"
      log "Message: #{json_message.inspect}"
      return nil
    end

    # log "Parsed: #{parsed.inspect}"
    # return nil

    if parsed.push.pub.data.type != "message"
      return
    end

    message_data = parsed.push.pub.data.data.data
    mentions = Array(Turnir::Parser::Vk::ContentDataMention).new

    text = String.build do |io|
      message_data.each do |data|
        if data.is_a?(Turnir::Parser::Vk::ContentDataText) && data.type == "text" && !data.content.empty?
          begin
            io << Array(JSON::Any).from_json(data.content)[0].to_s
          rescue ex
            log "Failed to parse content data: #{ex.inspect}"
            log "Content: #{data.inspect}"
          end
        end
        if data.is_a?(Turnir::Parser::Vk::ContentDataMention) && data.type == "mention"
          mentions << data
        end
      end
    end

    # log "text: #{text}"
    text = text.strip
    if text.empty?
      return nil
    end

    username = parsed.push.pub.data.data.author.displayName
    user_id = parsed.push.pub.data.data.author.id
    created_at = parsed.push.pub.data.data.createdAt
    message_id = parsed.push.pub.data.data.id
    
    channel_owner = @@reverse_channels_map.fetch(parsed.push.channel, nil)

    return Turnir::ChatStorage::Types::ChatMessage.from_vk_message(
      message: parsed,
      text: text,
      mentions: mentions,
      channel_owner: channel_owner
    )
  end

  def send_login(vk_token : String)
    @@message_counter += 1
    login_message = {
      "connect" => {"token" => vk_token, "name" => "js"},
      "id"      => @@message_counter,
    }
    @@websocket.try { |ws| ws.send(login_message.to_json) }
  end

  def subscribe_to_channel(channel_name : String)
    channel_id = get_vk_channel_id(channel_name)
    if channel_id.nil?
      log "Failed to get channel id for #{channel_name}"
      return
    end

    channel = "channel-chat:#{channel_id}"
    formatted_channel = "vkvideo/#{channel_name}"
    @@channels_map[channel_name] = formatted_channel
    @@reverse_channels_map[channel] = channel_name
    send_subscribe(channel)
  end

  def send_subscribe(channel : String)
    log("Subscribing to #{channel}")

    @@message_counter += 1
    subscribe_message = {
      "subscribe" => {"channel" => channel},
      "id"        => @@message_counter,
    }
    @@websocket.try do |ws|
      ws.send(subscribe_message.to_json)
      @@subscriptions_map[@@message_counter] = channel
    end
  end

  def stop
    @@websocket.try { |ws| ws.close }
  end

  struct VkAppConfig
    include JSON::Serializable
    property websocket : VkAppConfigWebsocket
  end

  struct VkAppConfigWebsocket
    include JSON::Serializable
    property token : String
  end

  def get_vk_app_config
    response = HTTP::Client.get "https://live.vkvideo.ru/"
    parsed = XML.parse_html(response.body)
    node = parsed.document.xpath_node("/html/body/script[@id='app-config']")
    node.try { |node| VkAppConfig.from_json node.content }
  end

  struct VkChannelInfo
    include JSON::Serializable
    property data : VkChannelInfoData
  end

  struct VkChannelInfoData
    include JSON::Serializable
    property owner : VkChannelInfoOwner
  end

  struct VkChannelInfoOwner
    include JSON::Serializable
    property id : Int32
    property name : String
    property nick : String
  end

  def get_vk_channel_id(name : String) : Int32 | Nil
    url = CHANNEL_INFO_URL.gsub("{{name}}", name)
    response = HTTP::Client.get url
    begin
      parsed = VkChannelInfo.from_json(response.body)
      return parsed.data.owner.id
    rescue ex
      log "Failed to get channel for #{name} exception: #{ex.inspect}"
      log "Response: #{response.body.inspect}"
      return nil
    end
  end
end
