require "json"
require "http/client"

require "../parser/goodgame"
require "../chat_storage/types"

module Turnir::Client::GoodgameWebsocket
  extend self

  WS_URL         = "wss://chat-1.goodgame.ru/chat2/"
  @@websocket : HTTP::WebSocket | Nil = nil
  WebsocketMutex = Mutex.new

  ChannelInfoURL = "https://goodgame.ru/api/4/users/{{name}}/stream"

  HEADERS = HTTP::Headers{
    "Origin" => "https://goodgame.ru",
    "Accept" => "application/json",
  }

  @@channels_map = {} of String => String

  PingMessage = {
    type: "ping",
    data: {} of String => String,
  }.to_json

  PongMessage = {
    type:   "pong",
    answer: "pong",
  }.to_json

  def log(msg : String)
    print "[GoodgameWS] "
    puts msg
  end

  def start(ready_channel : Channel(Nil), storage : Turnir::ChatStorage::Storage, channels_map : Hash(String, String))
    log "Starting Goodgame websocket"

    @@channels_map = channels_map

    WebsocketMutex.synchronize do
      if @@websocket.nil?
        @@websocket = HTTP::WebSocket.new(
          WS_URL,
          headers = HTTP::Headers{
            "Origin" => "https://goodgame.ru",
          },
        )

        @@websocket.try do |websocket|
          auth_msg = {
            type: "auth",
            data: {
              user_id: 0,
            },
          }.to_json
          websocket.send(auth_msg)
        end
      end
    end

    websocket = @@websocket

    if websocket.nil?
      log "Failed to create websocket"
      return
    end

    websocket.on_message do |msg|
      # log "WS message: #{msg}"
      parsed = parse_message(msg)
      if parsed
        storage.add_message(parsed)
      end
    end

    websocket.on_close do |code|
      log "Websocket Closed: #{code}"
      @@websocket = nil
    end

    spawn do
      loop do
        sleep 30.seconds
        if websocket.closed?
          log "Websocket closed, exiting..."
          break
        end
        begin
          websocket.send(PingMessage)
        rescue e
          log "Websocket ping error: #{e.inspect}"
          break
        end
      end
    end

    ready_channel.send(nil)
    websocket.run
    @@websocket = nil
  end

  def stop
    @@websocket.try &.close()
  end

  def parse_message(msg : String) : Turnir::ChatStorage::Types::ChatMessage | Nil
    if msg == PongMessage
      return nil
    end

    begin
      chat_event = Turnir::Parser::Goodgame::ChatEvent.from_json(msg)
    rescue e : JSON::Error
      log "Failed to parse message: #{e}, message: #{msg}"
      return nil
    end

    if chat_event.type == "success_join"
      begin
        join_msg = Turnir::Parser::Goodgame::JoinData.from_json(chat_event.data.to_json)
        Turnir::Client.on_subscribe(Turnir::Client::ClientType::GOODGAME, join_msg.channel_key)
      rescue e : JSON::Error
        log "Failed to parse join message: #{e}, message: #{msg}"
        return nil
      end
    end

    if chat_event.type == "message"
      begin
        msg = Turnir::Parser::Goodgame::MessageData.from_json(chat_event.data.to_json)
      rescue e : JSON::Error
        log "Failed to parse chat message: #{e}, message: #{msg}"
        return nil
      end
      return Turnir::ChatStorage::Types::ChatMessage.from_goodgame_message(msg)
    end
  end

  def subscribe_to_channel(channel_name : String)
    websocket = @@websocket
    if websocket.nil?
      log "Websocket is not connected"
      return
    end

    channel_id = get_channel_id(channel_name)
    if channel_id.nil?
      log "Failed to get channel id for #{channel_name}"
      return
    end

    channel_id = channel_id.to_s

    formatted_channel = "goodgame/#{channel_id}"
    @@channels_map[channel_name] = formatted_channel

    join_msg = {
      type: "join",
      data: {
        channel_id: channel_id,
        hidden:     0,
        reload:     false,
      },
    }.to_json

    websocket.try { |ws| ws.send(join_msg) }
  end

  def get_channel_id(channel_name : String) : Int32 | Nil
    channel_url = ChannelInfoURL.sub("{{name}}", channel_name)
    response = HTTP::Client.get(channel_url, headers: HEADERS)

    begin
      parsed = Turnir::Parser::Goodgame::ChannelInfo.from_json(response.body)
    rescue e : JSON::Error
      log "Failed to parse channel info: #{e}, response: #{response.body}"
      return nil
    end

    parsed.id
  end
end
