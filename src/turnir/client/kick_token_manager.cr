require "http/client"
require "json"

module Turnir::Client::KickTokenManager
  extend self

  struct TokenResponse
    include JSON::Serializable

    property access_token : String
    property token_type : String
    property expires_in : Int64
    property created_at : Int64
    property created_at_str : String
  end

  TOKEN_FILENAME = "kick_token.json"
  REFRESH_WINDOW = 10.minutes.to_i
  CHECK_INTERVAL = 5.minutes.to_i

  def log(msg)
    print "[KickToken] "
    puts msg
  end

  def request_new_token : TokenResponse | Nil
    client_id = Turnir::Config::KICK_CLIENT_ID
    client_secret = Turnir::Config::KICK_CLIENT_SECRET

    if client_id == "NO_CLIENT_ID" || client_secret == "NO_CLIENT_SECRET"
      log "KICK_CLIENT_ID or KICK_CLIENT_SECRET not set, cannot request token."
      return nil
    end

    begin
      response = HTTP::Client.post("https://api.kick.com/oauth/token",
        headers: HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"},
        form: {
          "grant_type"    => "client_credentials",
          "client_id"     => client_id,
          "client_secret" => client_secret,
        }
      )

      if response.status_code == 200
        body = JSON.parse(response.body).as_h
        body["created_at"] = JSON::Any.new(Time.utc.to_unix)
        body["created_at_str"] = JSON::Any.new(Time.utc.to_s)
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

    if force || token_response.nil? || token_expired?(token_response)
      log "Token expired or not found, requesting new token..."
      new_token = request_new_token
      if new_token.nil?
        log "Failed to request new token."
        return nil
      end
      save_token_response(new_token)
      Turnir::Config.set_kick_token(new_token.access_token)
      log "New token obtained successfully."
      return
    end

    if Turnir::Config.get_kick_token != token_response.access_token
      Turnir::Config.set_kick_token(token_response.access_token)
      log "Token updated"
    end

    if (Time.utc.to_unix + REFRESH_WINDOW) > (token_response.created_at + token_response.expires_in)
      log "Token will expire soon, requesting new token..."
      new_token = request_new_token
      if new_token.nil?
        log "Failed to request new token."
        return nil
      end
      save_token_response(new_token)
      Turnir::Config.set_kick_token(new_token.access_token)
      log "Token refreshed successfully."
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

