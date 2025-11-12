require "./vk_client"
require "./twitch_client"
require "./goodgame_client"
require "./kick_client"

module Turnir::Client
  extend self

  enum ClientType
    VKVIDEO
    TWITCH
    GOODGAME
    KICK
  end

  DOMAIN_TO_CLIENT_TYPE = {
    "vkvideo.ru"  => ClientType::VKVIDEO,
    "twitch.tv"   => ClientType::TWITCH,
    "goodgame.ru" => ClientType::GOODGAME,
    "kick.com"    => ClientType::KICK,
  }

  alias ClientModule = Turnir::Client::VkWebsocket | Turnir::Client::TwitchWebsocket | Turnir::Client::GoodgameWebsocket | Turnir::Client::KickClient

  def log(msg)
    print "[Client] "
    puts msg
  end

  enum ConnectionStatus
    DISCONNECTED
    CONNECTING
    CONNECTED
  end

  class Stream
    property client_type : ClientType
    property channel : String
    property status : ConnectionStatus

    def initialize(client_type : ClientType, channel : String, status : ConnectionStatus)
      @client_type = client_type
      @channel = channel
      @status = status
    end
  end

  STREAMS_STATUS_MAP       = Hash(String, Stream).new
  STREAMS_STATUS_MAP_MUTEX = Mutex.new

  class Client
    property client_type : ClientType
    property mod : ClientModule
    property fiber : Fiber | Nil = nil
    property ready_channel = Channel(Nil).new(0)
    property mutex = Mutex.new
    property storage : Turnir::ChatStorage::Storage
    property channels_map = {} of String => String

    def initialize(client_type : ClientType, mod : ClientModule)
      @client_type = client_type
      @mod = mod
      @storage = Turnir::ChatStorage::Storage.new
    end
  end

  CLIENTS = {
    ClientType::VKVIDEO  => Client.new(ClientType::VKVIDEO, Turnir::Client::VkWebsocket),
    ClientType::TWITCH   => Client.new(ClientType::TWITCH, Turnir::Client::TwitchWebsocket),
    ClientType::GOODGAME => Client.new(ClientType::GOODGAME, Turnir::Client::GoodgameWebsocket),
    ClientType::KICK     => Client.new(ClientType::KICK, Turnir::Client::KickClient),
  }

  def ensure_client_running(client_type : ClientType)
    client = CLIENTS[client_type]
    client_streams = STREAMS_STATUS_MAP.select { |k, v| k.downcase.starts_with?(client_type.to_s.downcase) }
    channels = client_streams.values.map { |k| k.channel }
    client.mutex.synchronize do
      if client.fiber.nil? || client.fiber.try &.dead?
        log "Starting client: #{client_type.to_s}"
        client.fiber = spawn do
          client.mod.start(client.ready_channel, client.storage, client.channels_map)
        end
        client.ready_channel.receive
        channels.each do |channel|
          log "Re-subscribing #{client_type.to_s} to channel: #{channel}"
          client.mod.subscribe_to_channel(channel)
        end
      end
    end
  end

  def get_messages(client_type : ClientType, channel : String, since : Int64, text_filter : String)
    client = CLIENTS[client_type]
    ensure_client_running(client_type)

    # log "Getting messages for #{channel} #{client.channels_map}"

    channel_internal = client.channels_map.fetch(channel, nil)
    if channel_internal.nil?
      return nil
    end

    client.storage.get_messages(channel_internal, since, text_filter)
  end

  def get_connections_statuses
    STREAMS_STATUS_MAP.map { |k, v| [k.downcase, v.status.to_s.downcase] }.to_h
  end

  def clear_all_storages
    CLIENTS.each do |_, client|
      client.storage.clear
    end
  end

  def client_restarter
    loop do
      sleep 3.minutes

      active_client_types = Set(ClientType).new
      STREAMS_STATUS_MAP_MUTEX.synchronize do
        STREAMS_STATUS_MAP.each do |_, stream|
          active_client_types.add(stream.client_type)
        end
      end

      active_client_types.each do |client_type|
        client = CLIENTS[client_type]
        if client.fiber.nil? || client.fiber.try(&.dead?)
          log "Client for #{client_type} is dead, restarting."
          ensure_client_running(client_type)
        end
      end
    end
  end

  def save_random_messages
    loop do
      sleep 1.minute

      all_messages = [] of Turnir::ChatStorage::Types::ChatMessage
      STREAMS_STATUS_MAP_MUTEX.synchronize do
        STREAMS_STATUS_MAP.each do |stream_name, stream|
          client = CLIENTS[stream.client_type]
          internal_channel = client.channels_map.fetch(stream.channel, nil)
          # log "Checking stream #{stream_name}: internal_channel=#{internal_channel.inspect}"
          if internal_channel
            messages = client.storage.get_last_messages(internal_channel, 10)
            # log "  Found #{messages.size} messages for #{stream_name}"
            all_messages.concat(messages)
          else
            # log "  No internal_channel mapping for #{stream.channel}"
          end
        end
      end

      # log "Total messages collected: #{all_messages.size}"

      if all_messages.any?
        random_messages = all_messages.sample(8)
        # log "Saving random message from #{random_message.channel}: #{random_message.user.username}: #{random_message.message[0..50]}"
        random_messages.each do |msg|
          begin
            Turnir::DbStorage.save_message(
              created_at: (msg.ts / 1000).to_i32,
              message: msg.message,
              username: msg.user.username,
              chat_name: msg.channel
            )
            # log "Message saved successfully to DB"
          rescue ex
            log "Failed to save random message to DB: #{ex}"
          end
        end
        clear_all_storages
        # log "Storage cleared"
      else
        # log "No messages to save"
      end

      # delete messages 6 hours old
      Turnir::DbStorage.delete_old_messages(Time.utc.to_unix.to_i32 - 6 * 3600)
    end
  end

  def stream_activity_checker
    loop do
      STREAMS_STATUS_MAP.each do |_, stream|
        client = CLIENTS[stream.client_type]
        last_message_ts = client.storage.get_last_message_ts(stream.channel)
        if stream.status == ConnectionStatus::CONNECTED && last_message_ts > 0 && last_message_ts + 1.minutes < Time.utc.to_unix
          stream.status = ConnectionStatus::DISCONNECTED
        end
      end
      sleep 60.seconds
    end
  end

  def subscribe_to_channel_if_not_subscribed(client_type : ClientType, channel_name : String) : ConnectionStatus
    client = CLIENTS[client_type]
    stream = "#{client_type.to_s.downcase}/#{channel_name}"
    stream_status = get_stream_status(stream)

    if stream_status == ConnectionStatus::DISCONNECTED
      subscribe_to_channel(client_type, channel_name)
    end
    stream_status
  end

  def subscribe_to_channel(client_type : ClientType, channel_name : String)
    client = CLIENTS[client_type]
    client.mod.subscribe_to_channel(channel_name)
  end

  def on_subscribe(client : ClientType, channel : String)
    stream_name = "#{client.to_s.downcase}/#{channel}"
    stream = STREAMS_STATUS_MAP.fetch(stream_name, nil)
    if stream.nil?
      stream = Stream.new(client_type: client, channel: channel, status: ConnectionStatus::CONNECTED)
      STREAMS_STATUS_MAP_MUTEX.synchronize do
        STREAMS_STATUS_MAP[stream_name] = stream
      end
      return
    end
    stream.status = ConnectionStatus::CONNECTED
  end

  def get_stream_status(stream_name : String) : ConnectionStatus
    stream = STREAMS_STATUS_MAP.fetch(stream_name, nil)
    if stream
      return stream.status
    end
    ConnectionStatus::DISCONNECTED
  end

  def disconnect_streams_for_client(client_type : ClientType)
    downcased = client_type.to_s.downcase
    STREAMS_STATUS_MAP_MUTEX.synchronize do
      STREAMS_STATUS_MAP.each do |_, stream|
        if stream.client_type == client_type
          stream.status = ConnectionStatus::DISCONNECTED
        end
      end
    end
  end

  def clear_streams_for_client(client_type : ClientType)
    STREAMS_STATUS_MAP_MUTEX.synchronize do
      STREAMS_STATUS_MAP.reject! do |name, stream|
        stream.client_type == client_type
      end
    end
  end
end
