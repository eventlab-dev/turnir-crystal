require "http/client"
require "json"
require "./types"
require "./seventv_client"
require "./twitch_client"
require "./bttv_client"
require "./ffz_client"
require "../config"

module Turnir::Emotes
  # Module-level method to update all emotes
  def self.update_all : Hash(String, Int32)
    puts "Starting emote update process"
    stats = {
      "users" => 0,
      "channels_processed" => 0,
      "emotes_updated" => 0,
      "errors" => 0,
    }

    begin
      # Fetch users from CHANNELS_API_URL (same as fetch_initial_channels)
      puts "Fetching users from CHANNELS_API_URL..."
      users = fetch_users_from_channels_api
      stats["users"] = users.size
      puts "Fetched #{users.size} users"

      if users.empty?
        puts "No users found, skipping emote update"
        return stats
      end

      # Collect Twitch users
      puts "Collecting Twitch users..."
      twitch_users = {} of String => String  # login => user_slug
      users.each_with_index do |user, index|
        begin
          if user.main_platform.try(&.downcase) == "twitch"
            twitch_link = user.twitch_stream_link
            slug = user.slug || extract_twitch_login(twitch_link || "")
            
            if twitch_link && !twitch_link.empty? && slug && !slug.empty?
              login = extract_twitch_login(twitch_link)
              if login && !login.empty?
                twitch_users[login] = slug
                puts "Added Twitch user: #{login} (#{slug})"
              else
                puts "Warning: Could not extract Twitch login from '#{twitch_link}' for user '#{slug}'"
              end
            else
              puts "Warning: Missing twitch_stream_link or slug for Twitch user ##{index}"
            end
          end
        rescue ex
          puts "Error processing user ##{index}: #{ex.message}"
        end
      end

      puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      puts "Found #{twitch_users.size} Twitch users to process"
      if twitch_users.size > 0
        puts "Users: #{twitch_users.keys.join(", ")}"
      end
      puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
      
      # Update global emotes
      if twitch_users.size > 0
        puts "Updating global emotes (7TV + BTTV + FFZ + Twitch)"
        
        # Initialize clients
        puts "Initializing clients..."
        seventv_client = SevenTVClient.new
        twitch_client = TwitchEmoteClient.new(
          client_id: Config::TWITCH_CLIENT_ID,
          access_token: Config.get_twitch_token
        )
        bttv_client = BTTVClient.new
        ffz_client = FFZClient.new
        puts "Clients initialized"

        # Update 7TV global emotes
        begin
          count = seventv_client.update_and_save_global_emotes
          stats["emotes_updated"] = stats["emotes_updated"] + count
        rescue ex
          puts "Error updating 7TV global emotes: #{ex}"
          stats["errors"] = stats["errors"] + 1
        end

        # Update BTTV global emotes
        begin
          count = bttv_client.update_and_save_global_emotes
          stats["emotes_updated"] = stats["emotes_updated"] + count
        rescue ex
          puts "Error updating BTTV global emotes: #{ex}"
          stats["errors"] = stats["errors"] + 1
        end

        # Update FFZ global emotes
        begin
          count = ffz_client.update_and_save_global_emotes
          stats["emotes_updated"] = stats["emotes_updated"] + count
        rescue ex
          puts "Error updating FFZ global emotes: #{ex}"
          stats["errors"] = stats["errors"] + 1
        end

        # Update Twitch global emotes
        begin
          count = twitch_client.update_and_save_global_emotes
          stats["emotes_updated"] = stats["emotes_updated"] + count
        rescue ex
          puts "Error updating Twitch global emotes: #{ex}"
          stats["errors"] = stats["errors"] + 1
        end

        # Resolve Twitch logins to IDs
        login_to_id = twitch_client.get_user_ids_batch(twitch_users.keys)

        # Update channel emotes
        twitch_users.each do |login, user_slug|
          channel_id = login_to_id[login.downcase]?
          unless channel_id
            puts "Could not resolve Twitch login '#{login}' to ID, skipping"
            next
          end

          begin
            puts "Updating channel emotes for Twitch/#{login} (ID: #{channel_id}, user: #{user_slug})"
            
            # Update 7TV channel emotes
            count = seventv_client.update_and_save_channel_emotes(channel_id, user_slug)
            stats["emotes_updated"] = stats["emotes_updated"] + count
            
            # Update BTTV channel emotes
            count = bttv_client.update_and_save_channel_emotes(channel_id, user_slug)
            stats["emotes_updated"] = stats["emotes_updated"] + count
            
            # Update FFZ channel emotes
            count = ffz_client.update_and_save_channel_emotes(channel_id, user_slug)
            stats["emotes_updated"] = stats["emotes_updated"] + count
            
            # Update Twitch channel emotes
            count = twitch_client.update_and_save_channel_emotes(channel_id, user_slug)
            stats["emotes_updated"] = stats["emotes_updated"] + count
            
            stats["channels_processed"] = stats["channels_processed"] + 1
          rescue ex
            puts "Error updating channel emotes for #{login}: #{ex}"
            stats["errors"] = stats["errors"] + 1
          end
        end
      end

    rescue ex
      puts "Fatal error in emote update:"
      puts "   Error: #{ex.class.name}"
      puts "   Message: #{ex.message}"
      puts "   Backtrace:"
      ex.backtrace.each { |line| puts "     #{line}" }
      stats["errors"] = stats["errors"] + 1
    end

    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    puts "Emote update completed"
    puts "Stats: #{stats}"
    puts "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    stats
  end

  # Fetch users from CHANNELS_API_URL (same source as fetch_initial_channels)
  private def self.fetch_users_from_channels_api : Array(ChannelUser)
    url = Config.channels_api_url
    if url.empty?
      puts "CHANNELS_API_URL is not set"
      return [] of ChannelUser
    end
    
    begin
      response = HTTP::Client.get(url)
      if response.status_code == 200
        data = JSON.parse(response.body)
        users_array = data["users"]?.try(&.as_a) || [] of JSON::Any
        
        users = [] of ChannelUser
        users_array.each_with_index do |user_data, index|
          begin
            # Safely extract string values, handling null
            # Check if value exists and is not null before calling as_s
            main_platform = nil
            if main_platform_val = user_data["main_platform"]?
              main_platform = main_platform_val.raw.as?(String)
            end
            
            twitch_stream_link = nil
            if twitch_link_val = user_data["twitch_stream_link"]?
              twitch_stream_link = twitch_link_val.raw.as?(String)
            end
            
            slug = nil
            if slug_val = user_data["slug"]?
              slug = slug_val.raw.as?(String)
            end
            
            users << ChannelUser.new(
              main_platform: main_platform,
              twitch_stream_link: twitch_stream_link,
              slug: slug
            )
          rescue ex
            puts "Warning: Error parsing user ##{index}: #{ex.message}"
            # Continue with next user
          end
        end
        
        puts "Found #{users.size} users from CHANNELS_API_URL"
        return users
      else
        puts "Failed to fetch users from CHANNELS_API_URL: #{response.status_code}"
        return [] of ChannelUser
      end
    rescue ex
      puts "Error fetching users from CHANNELS_API_URL: #{ex}"
      puts "  Error class: #{ex.class.name}"
      puts "  Error message: #{ex.message}"
      if ex.backtrace
        puts "  Backtrace:"
        ex.backtrace.first(5).each { |line| puts "    #{line}" }
      end
      return [] of ChannelUser
    end
  end
  
  # Simple struct for channel user data
  struct ChannelUser
    property main_platform : String?
    property twitch_stream_link : String?
    property slug : String?
    
    def initialize(@main_platform : String?, @twitch_stream_link : String?, @slug : String?)
    end
  end

  # Extract Twitch login from stream link
  private def self.extract_twitch_login(link : String) : String?
    return nil if link.empty?
    
    login = if link.includes?("twitch.tv/")
      parts = link.split("twitch.tv/")
      parts.size > 1 ? parts[-1].strip("/").downcase : nil
    else
      link.strip("/").downcase
    end
    
    # Return nil if login is empty or contains invalid characters
    return nil if login.nil? || login.empty?
    
    login
  end
end

