require "json"
require "http/client"

require "../parser/kick"

module Turnir::Client::KickClient
  extend self

  @@stop = Atomic(Int32).new(0)

  def log(msg)
    print "[KICK] "
    puts msg
  end

  @@storage : Turnir::ChatStorage::Storage | Nil = nil
  @@channels_map = {} of String => String
  @@channel_to_broadcaster = {} of String => Int64
  @@broadcaster_to_channel = {} of Int64 => String

  def get_headers
    token = Turnir::Config.get_kick_token
    token = Turnir::Config::KICK_OAUTH_TOKEN if token.empty?
    
    HTTP::Headers{
      "Authorization" => "Bearer #{token}",
      "Content-Type"  => "application/json",
    }
  end

  @@subscriptions = [] of Turnir::Parser::Kick::SubscriptionData

  def start(sync_channel : Channel(Nil), storage : Turnir::ChatStorage::Storage, channels_map : Hash(String, String))
    log "Starting Kick"

    @@storage = storage
    @@channels_map = channels_map

    @@stop.set(0)

    refresh_subscriptions()

    sync_channel.send(nil)
    loop do
      # Simulate some work
      sleep 60.seconds

      # Check if the sync_channel is closed
      if sync_channel.closed?
        log "Sync channel closed, exiting..."
        break
      end
      # Check if the stop flag is set
      if @@stop.get == 1
        log "Stopping Kick client"
        break
      end
    end

    unsubscribe_from_all_channels
  end

  def handle_message(msg : String)
    begin
      parsed = Turnir::Parser::Kick::ChatMessage.from_json(msg)
      if parsed
        # Process the parsed message
        # log "Parsed message: #{parsed}"
        msg = Turnir::ChatStorage::Types::ChatMessage.from_kick_message(parsed)
        @@channels_map[msg.channel] = msg.channel
        @@storage.try { |s|
          s.add_message(msg)
        }
      else
        log "Failed to parse message: #{msg}"
      end
    rescue ex : Exception
      log "Error while parsing message: #{ex.inspect}"
      log "Failed to parse message: #{msg.inspect}"
    end
  end

  def subscribe_to_channel(channel_name : String)
    log "Subscribing to channel: #{channel_name}"
    formatted_channel = "kick/#{channel_name}"
    @@channels_map[channel_name] = formatted_channel

    channel_id : Int64 | Nil = @@channel_to_broadcaster.fetch(channel_name, nil)

    if channel_id.nil?
      channel_info = fetch_stream_info(channel_name)
      if channel_info.nil?
        log "Failed to get channel info for #{channel_name}"
        return
      end
      channel_id = channel_info.broadcaster_user_id
      @@channel_to_broadcaster[channel_name] = channel_id
      @@broadcaster_to_channel[channel_id] = channel_name
    end

    response = HTTP::Client.post("https://api.kick.com/public/v1/events/subscriptions",
      headers: get_headers,
      body: {
        "broadcaster_user_id": channel_id,
        "events":              [{
          "name":    "chat.message.sent",
          "version": 1,
        }],
        "method": "webhook",
      }.to_json
    )
    if response.status_code != 200
      log "Failed to subscribe to channel: #{response.status_code} #{response.body}"
      log "Response: #{response.body}"
      return
    end

    Turnir::Client.on_subscribe(
      Turnir::Client::ClientType::KICK,
      channel_name,
    )
  end

  def stop
    @@stop.set(1)
  end

  def refresh_subscriptions
    response = HTTP::Client.get(
      "https://api.kick.com/public/v1/events/subscriptions",
      headers: get_headers
    )
    begin
      parsed = Turnir::Parser::Kick::SubscriptionsResponse.from_json(response.body)
      @@subscriptions = parsed.data

      @@subscriptions.each do |s|
        channel = @@broadcaster_to_channel.fetch(s.broadcaster_user_id, nil)
        if channel
          Turnir::Client.on_subscribe(
            Turnir::Client::ClientType::KICK,
            channel,
          )
        end
      end
    rescue ex
      log "Failed to fetch subscriptions: #{ex.inspect}"
      log "Response: #{response.body}"
    end
  end

  def unsubscribe_from_all_channels
    qs = @@subscriptions.map { |s| "id=#{s.id}" }.join("&")
    if qs.empty?
      log "No subscriptions to unsubscribe from"
      return
    end

    begin
      response = HTTP::Client.delete(
        "https://api.kick.com/public/v1/events/subscriptions?#{qs}",
        headers: get_headers
      )
      if response.status_code != 204
        log "Failed to unsubscribe from channel: #{response.status_code} #{response.body}"
      end
    rescue ex
      log "Failed to unsubscribe: #{ex.inspect}"
    end
  end

  def fetch_stream_info(channel_name : String)
    response = HTTP::Client.get("https://api.kick.com/public/v1/channels?slug=#{channel_name}", headers: get_headers)
    begin
      parsed = Turnir::Parser::Kick::ChannelsResponse.from_json(response.body)
      if parsed.data.size == 0
        return nil
      end
      parsed.data[0]
    rescue ex
      log "Failed to parse stream info: #{ex.inspect}"
      log "Response: #{response.body}"
      nil
    end
  end
end
