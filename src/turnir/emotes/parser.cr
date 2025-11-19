require "./types"

module Turnir::Emotes
  # Emote parser for converting emote codes to [emote|URL|NAME] or [emote|URL|NAME|zw] format in messages
  # For Twitch: replaces emote codes like "Kappa" with "[emote|https://...|Kappa]"
  # For zero-width emotes: adds |zw flag "[emote|https://...|cvMask|zw]"
  # irc_emotes: Hash mapping emote_id to emote_code (text) from IRC message
  class Parser

    # Parse message and replace emote codes with [emote|URL|NAME|zw?] format
    # For Twitch: replaces emote codes like "Kappa" with "[emote|https://...|Kappa]"
    # For zero-width (overlay) emotes: adds |zw flag
    # irc_emotes: Hash mapping emote_id to emote_code (text) from IRC message
    def self.parse_twitch_message(text : String, user_slug : String?, irc_emotes : Hash(String, String) = Hash(String, String).new) : String
      return text if text.empty?

      result = text

      # First, process Twitch emotes from IRC message (if provided)
      # Format: { "emote_id" => "emote_code" }
      if !irc_emotes.empty?
        irc_emotes.each do |emote_id, emote_code|
          emote_url = "https://static-cdn.jtvnw.net/emoticons/v2/#{emote_id}/default/dark/2.0"
          escaped_code = Regex.escape(emote_code)
          
          pattern = /(^|\s)#{escaped_code}(?=\s|$)/
          
          replacement = "\\1[emote|#{emote_url}|#{emote_code}]"
          result = result.gsub(pattern, replacement)
        end
      end

      # Then, process 7TV/BTTV/FFZ emotes from memory (but skip Twitch emotes)
      # Get emotes from memory (only 7TV/BTTV/FFZ, no Twitch)
      emotes = Emotes.get_emotes("twitch", user_slug)
      
      if !emotes.empty?
        # Sort by length (longest first) to avoid partial matches
        sorted_codes = emotes.keys.sort_by { |k| -k.size }

        sorted_codes.each do |code|
          emote = emotes[code]
          escaped_code = Regex.escape(code)
          
          pattern = /(^|\s)#{escaped_code}(?=\s|$)/
          
          replacement = if emote.is_zero_width
            "\\1[emote|#{emote.url}|#{code}|zw]"
          else
            "\\1[emote|#{emote.url}|#{code}]"
          end
          
          result = result.gsub(pattern, replacement)
        end
      end

      result
    end
  end
end






