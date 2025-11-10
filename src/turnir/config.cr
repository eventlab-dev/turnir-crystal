require "dotenv"

Dotenv.load?

module Turnir::Config
  extend self

  BUILD_TIME = {{ "#{`date`.strip}" }}

  def database_url
    ENV.fetch("DATABASE_URL", "mysql://crystal_user:pass@127.0.0.1/aukus4")
  end

  def webserver_ip
    ENV.fetch("IP", "127.0.0.1")
  end

  def webserver_port
    ENV.fetch("PORT", "8080").to_i
  end

  def client_restarter_interval_seconds
    ENV.fetch("CLIENT_RESTARTER_INTERVAL_SECONDS", "180").to_i
  end

  def channels_api_url
    ENV.fetch("CHANNELS_API_URL", "https://api.eventlab.dev/api/users?is_active=1&events=aukus4")
  end

  TWITCH_OAUTH_TOKEN = ENV.fetch("TWITCH_OAUTH", "NO_TOKEN")
  TWITCH_CLIENT_ID   = ENV.fetch("TWITCH_CLIENT_ID", "NO_CLIENT_ID")

  TWITCH_CLIENT_SECRET = ENV.fetch("TWITCH_CLIENT_SECRET", "NO_CLIENT_SECRET")
  @@twitch_access_token : String = ""

  KICK_OAUTH_TOKEN = ENV.fetch("KICK_OAUTH", "NO_TOKEN")
  KICK_CLIENT_ID = ENV.fetch("KICK_CLIENT_ID", "NO_CLIENT_ID")
  KICK_CLIENT_SECRET = ENV.fetch("KICK_CLIENT_SECRET", "NO_CLIENT_SECRET")
  @@kick_access_token : String = ""

  def get_twitch_token
    @@twitch_access_token
  end

  def set_twitch_token(token : String)
    @@twitch_access_token = token
  end

  def get_kick_token
    @@kick_access_token
  end

  def set_kick_token(token : String)
    @@kick_access_token = token
  end
end
