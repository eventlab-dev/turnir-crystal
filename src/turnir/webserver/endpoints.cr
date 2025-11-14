require "http/server"
require "http/client"
require "json"
require "../client/client"
require "../config"
require "./utils"
require "../emotes/update"

module Turnir::Webserver
  extend self

  URL_MAP = {
    /^\/external\/kick-hook$/ => ->kick_web_hook(HTTP::Server::Context),
    /^\/test$/ => ->test_endpoint(HTTP::Server::Context),
    /^\/emotes\/update$/ => ->update_emotes_endpoint(HTTP::Server::Context),
  }

  class MethodNotSupported < Exception
  end

  def log(msg)
    print "[WebServer #{Fiber.current}] "
    puts msg
  end

  def kick_web_hook(context : HTTP::Server::Context)
    if context.request.method != "POST"
      raise MethodNotSupported.new("Method #{context.request.method} not supported")
    end

    event_type = context.request.headers["Kick-Event-Type"]?
    if event_type != "chat.message.sent"
      log "Unsupported KICK event type: #{event_type}"
      context.response.status = HTTP::Status::OK
      context.response.content_type = "text/plain"
      context.response.print "unsupported"
      return
    end

    message_id = context.request.headers["Kick-Event-Message-Id"]?
    message_ts = context.request.headers["Kick-Event-Message-Timestamp"]?
    kick_signature = context.request.headers["Kick-Event-Signature"]?

    if message_id.nil? || message_ts.nil? || kick_signature.nil?
      log "Missing KICK headers"
      context.response.status = HTTP::Status::OK
      context.response.content_type = "text/plain"
      context.response.print "missing headers"
      return
    end

    body = context.request.body.try do |data|
      data.gets_to_end
    end

    if body.nil?
      log "Missing KICK body"
      context.response.status = HTTP::Status::OK
      context.response.content_type = "text/plain"
      context.response.print "missing body"
      return
    end

    signed_data = "#{message_id}.#{message_ts}.#{body}"

    valid_signature = false
    begin
      valid_signature = Utils.verify_kick_signature(
        signed_data,
        kick_signature,
      )
    rescue ex : Exception
      log "Signature verification failed with exception: #{ex.inspect}"
      context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
      context.response.content_type = "text/plain"
      context.response.print "signature verification error"
      return
    end

    if !valid_signature
      context.response.status = HTTP::Status::OK
      context.response.content_type = "text/plain"
      context.response.print "invalid signature"
      return
    end

    begin
      Turnir::Client::KickClient.handle_message(body)
    rescue ex : Exception
      log "Failed to handle kick message: #{ex.inspect}"
    end

    context.response.content_type = "application/json"
    context.response.print ({"status" => "ok"}).to_json
  end

  def test_endpoint(context : HTTP::Server::Context)
    log "Test endpoint called"
    context.response.status = HTTP::Status::OK
    context.response.content_type = "application/json"
    context.response.print ({"status" => "ok", "message" => "test successful"}).to_json
  end

  def update_emotes_endpoint(context : HTTP::Server::Context)
    log "Emote update endpoint called"
    
    spawn do
      begin
        stats = Turnir::Emotes.update_all
        log "Emote update completed with stats: #{stats}"
      rescue ex
        log "Error in emote update task: #{ex}"
        log ex.backtrace.join("\n")
      end
    end

    context.response.status = HTTP::Status::OK
    context.response.content_type = "application/json"
    context.response.print ({"status" => "ok", "message" => "Emote update started in background"}).to_json
  end

  def start
    server = HTTP::Server.new do |context|
      context.response.headers["Access-Control-Allow-Origin"] = "http://localhost:5173"
      context.response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
      context.response.headers["Access-Control-Allow-Headers"] = "Content-Type, Authorization"

      start = Time.utc
      path = context.request.path
      method = context.request.method
      query = context.request.query
      response = context.response

      url_match = URL_MAP.each.find do |pattern, handler|
        path.match(pattern)
      end
      if url_match
        if context.request.method == "OPTIONS"
          context.response.status = HTTP::Status::OK
          context.response.content_type = "text/plain"
          context.response.print "OK"
          next
        end

        handler = url_match[1]
        begin
          handler.call(context)
        rescue ex : MethodNotSupported
          context.response.status = HTTP::Status::METHOD_NOT_ALLOWED
          context.response.content_type = "text/plain"
          context.response.print "Method Not Allowed "
          context.response.print context.request.method
        rescue ex
          context.response.status = HTTP::Status::INTERNAL_SERVER_ERROR
          context.response.content_type = "text/plain"
          context.response.print "Internal Server Error"
          log "WebServer error: "
          log ex
          log ex.backtrace
          log "for request: "
        end
      else
        context.response.status = HTTP::Status::NOT_FOUND
        context.response.content_type = "text/plain"
        context.response.print "Not Found"
      end
      time_passed = Time.utc - start

      if query
        log "> #{method} #{path}?#{query} : #{response}"
      else
        log "> #{method} #{path} : #{response}"
      end
      log "< #{context.response.status} (#{time_passed.nanoseconds/100_000}ms)"
    end

    log "Starting webserver"
    ip = Turnir::Config.webserver_ip
    port = Turnir::Config.webserver_port

    address = server.bind_tcp ip, port
    log "Listening on http://#{address}"
    server.listen
  end
end
