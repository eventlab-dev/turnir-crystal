require "http/client"
require "json"

module Turnir::Client::TwitchTokenManager
  extend self

  struct TokenResponse
    include JSON::Serializable

    property access_token : String
    property refresh_token : String
    property expires_in : Int64
    property scope : Array(String)
    property token_type : String
    property created_at : Int64
    property created_at_str : String
  end

  TOKEN_FILENAME = "twitch_token.json"
  REFRESH_WINDOW = 10.minutes.to_i
  CHECK_INTERVAL = 5.minutes.to_i

  def log(msg)
    print "[TwitchToken] "
    puts msg
  end

  def request_new_token : TokenResponse | Nil
    client_id = Turnir::Config::TWITCH_CLIENT_ID
    client_secret = Turnir::Config::TWITCH_CLIENT_SECRET

    if client_id == "NO_CLIENT_ID" || client_secret == "NO_CLIENT_SECRET"
      log "TWITCH_CLIENT_ID or TWITCH_CLIENT_SECRET not set, cannot request token."
      return nil
    end

    begin
      response = HTTP::Client.post("https://id.twitch.tv/oauth2/token",
        headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        form: {
          "client_id"     => client_id,
          "client_secret" => client_secret,
          "grant_type"    => "client_credentials",
        }
      )

      if response.status_code == 200
        body = JSON.parse(response.body).as_h
        body["created_at"] = JSON::Any.new(Time.utc.to_unix)
        body["created_at_str"] = JSON::Any.new(Time.utc.to_s)
        body["refresh_token"] = JSON::Any.new("")
        body["scope"] = JSON::Any.new([] of JSON::Any)
        TokenResponse.from_json(body.to_json)
      else
        log "Failed to request token: #{response.status_code} #{response.body}"
        nil
      end
    rescue ex
      log "Error requesting token: #{ex.inspect}"
      nil
    end
  end

  def do_refresh_query(refresh_token : String) : TokenResponse | Nil
    response = HTTP::Client.post("https://id.twitch.tv/oauth2/token",
      headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
      form: {
        "client_id"     => Turnir::Config::TWITCH_CLIENT_ID,
        "client_secret" => Turnir::Config::TWITCH_CLIENT_SECRET,
        "grant_type"    => "refresh_token",
        "refresh_token" => refresh_token,
      }
    )

    if response.status_code == 200
      body = JSON.parse(response.body).as_h
      body["created_at"] = JSON::Any.new(Time.utc.to_unix)
      body["created_at_str"] = JSON::Any.new(Time.utc.to_s)
      TokenResponse.from_json(body.to_json)
    else
      log "Failed to refresh token: #{response.status_code} #{response.body}"
      nil
    end
  end

  def save_token_response(token_response : TokenResponse)
    File.write(TOKEN_FILENAME, token_response.to_json)
  end

  def load_token_response : TokenResponse | Nil
    if File.exists?(TOKEN_FILENAME)
      TokenResponse.from_json(
        File.read(TOKEN_FILENAME)
      )
    else
      nil
    end
  end

  def refresh_token(force : Bool = false)
    token_response = load_token_response

    if token_response.nil?
      log "No token file found."
      
      new_token = request_new_token
      if !new_token.nil?
        save_token_response(new_token)
        Turnir::Config.set_twitch_token(new_token.access_token)
        log "New token obtained via client credentials (for API only, IRC will use anonymous)"
        return
      end
      
      static_token = Turnir::Config::TWITCH_OAUTH_TOKEN
      if static_token != "NO_TOKEN" && !static_token.empty?
        Turnir::Config.set_twitch_token(static_token)
        log "Using static TWITCH_OAUTH token"
      else
        log "No token available. IRC will use anonymous connection (read-only)"
      end
      return nil
    end

    if Turnir::Config.get_twitch_token != token_response.access_token
      Turnir::Config.set_twitch_token(token_response.access_token)
      log "Token updated"
    end

    if force || token_expired?(token_response) || (Time.utc.to_unix + REFRESH_WINDOW) > (token_response.created_at + token_response.expires_in)
      if !token_response.refresh_token.empty?
        new_token_response = do_refresh_query(token_response.refresh_token)
        if new_token_response.nil?
          log "Failed to refresh token via refresh_token."
          return nil
        end
        save_token_response(new_token_response)
        Turnir::Config.set_twitch_token(new_token_response.access_token)
        log "Token refreshed via refresh_token successfully."
      else
        log "Token will expire soon, requesting new token via client credentials..."
        new_token = request_new_token
        if new_token.nil?
          log "Failed to request new token."
          return nil
        end
        save_token_response(new_token)
        Turnir::Config.set_twitch_token(new_token.access_token)
        log "Token refreshed via client credentials successfully."
      end
    end
  end

  def token_expired?(token_response : TokenResponse) : Bool
    Time.utc.to_unix > (token_response.created_at + token_response.expires_in)
  end

  def refresh_loop
    loop do
      refresh_token
      sleep CHECK_INTERVAL
    end
  end
end
