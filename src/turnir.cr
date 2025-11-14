require "./turnir/webserver/endpoints"
require "./turnir/client/client"
require "./turnir/client/twitch_token_manager"
require "./turnir/client/kick_token_manager"
require "./turnir/db_storage"
require "./turnir/config"
require "./turnir/emotes/update"
require "http/client"
require "json"

struct ApiResponse
  include JSON::Serializable

  property users : Array(User)
end

struct User
  include JSON::Serializable

  property main_platform : String?
  property vk_stream_link : String?
  property kick_stream_link : String?
  property twitch_stream_link : String?
  property slug : String?
end

puts "Starting Turnir build: #{Turnir::Config::BUILD_TIME}"

def fetch_initial_channels
  url = Turnir::Config.channels_api_url
  if url.empty?
    puts "CHANNELS_API_URL is not set. No initial channels to connect to."
    return [] of String
  end

  begin
    response = HTTP::Client.get(url)
    if response.status_code == 200
      api_response = ApiResponse.from_json(response.body)
      channels = [] of String
      api_response.users.each do |user|
        if platform_name = user.main_platform
          platform = platform_name.downcase
          link = case platform
                 when "vk"
                   user.vk_stream_link
                 when "kick"
                   user.kick_stream_link
                 when "twitch"
                   user.twitch_stream_link
                 else
                   nil
                 end

          if link
            parts = link.split('/')
            if parts.size > 0
              channel_name = parts[-1]
              domain = case platform
                       when "vk"
                         "vkvideo.ru"
                       when "kick"
                         "kick.com"
                       when "twitch"
                         "twitch.tv"
                       else
                         ""
                       end
              if !domain.empty? && !channel_name.empty?
                channels << "#{domain}/#{channel_name}"
              end
            end
          end
        end
      end
      channels
    else
      puts "Failed to fetch initial channels from API: #{response.status_code} #{response.body}"
      [] of String
    end
  rescue ex
    puts "Error fetching initial channels from API: #{ex}"
    [] of String
  end
end

Turnir::DbStorage.create_tables

channels_by_platform = Hash(Turnir::Client::ClientType, Array(String)).new

fetch_initial_channels.each do |channel_string|
  puts "Processing channel: #{channel_string}"
  parts = channel_string.split("/")
  if parts.size == 2
    domain, channel_name = parts
    platform = Turnir::Client::DOMAIN_TO_CLIENT_TYPE.fetch(domain, nil)
    if platform
      channels_by_platform[platform] ||= [] of String
      channels_by_platform[platform] << channel_name
    else
      puts "Unknown platform: #{domain}"
    end
  end
end

Turnir::Client::TwitchTokenManager.refresh_token(force: false)
Turnir::Client::KickTokenManager.refresh_token(force: false)

spawn do
  Turnir::Client::TwitchTokenManager.refresh_loop
end

spawn do
  Turnir::Client::KickTokenManager.refresh_loop
end

channels_by_platform.each do |platform, channels|
  Turnir::Client.ensure_client_running(platform)
  channels.each do |channel_name|
    Turnir::Client.subscribe_to_channel(platform, channel_name)
  end
end



spawn do
  Turnir::Client.client_restarter
end

spawn do
  Turnir::Client.save_random_messages
end

spawn do
  emote_update_interval = ENV.fetch("EMOTE_UPDATE_INTERVAL_SECONDS", "3600").to_i
  puts "Starting emote updater loop TEST (interval: #{emote_update_interval}s)"
  
  # Run first update immediately on startup
  begin
    puts "Running initial emote update"
    stats = Turnir::Emotes.update_all
    puts "Initial emote update completed: #{stats}"
  rescue ex
    puts "Error in initial emote update: #{ex}"
    puts ex.backtrace.join("\n")
  end
  
  loop do
    begin
      sleep emote_update_interval.seconds
      puts "Running periodic emote update"
      stats = Turnir::Emotes.update_all
      puts "Periodic emote update completed: #{stats}"
    rescue ex
      puts "Error in periodic emote update: #{ex}"
      puts ex.backtrace.join("\n")
    end
  end
end

Turnir::Webserver.start
