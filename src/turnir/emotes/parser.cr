require "./types"

module Turnir::Emotes
  # Emote parser for converting emote codes to [emote|URL|NAME] format in messages
  class Parser

    # Parse message and replace emote codes with [emote|URL|NAME] format
    # For Twitch: replaces emote codes like "Kappa" with "[emote|https://...|Kappa]"
    # irc_emotes: Hash mapping emote_id to emote_code (text) from IRC message
    def self.parse_twitch_message(text : String, user_slug : String?, irc_emotes : Hash(String, String) = Hash(String, String).new) : String
      return text if text.empty?

      result = text

      # First, process Twitch emotes from IRC message (if provided)
      # Format: { "emote_id" => "emote_code" }
      if !irc_emotes.empty?
        irc_emotes.each do |emote_id, emote_code|
          # Build URL for Twitch emote
          emote_url = "https://static-cdn.jtvnw.net/emoticons/v2/#{emote_id}/default/dark/2.0"
          escaped_code = Regex.escape(emote_code)
          
          # Build pattern based on whether code contains special characters
          if emote_code.match(/^\w+$/)
            pattern = /\b#{escaped_code}\b/
          else
            pattern = /(?<!\w)#{escaped_code}(?!\w)/
          end
          
          replacement = "[emote|#{emote_url}|#{emote_code}]"
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
          
          # Build pattern based on whether code contains special characters
          # For codes with only word characters: use word boundaries \bCODE\b
          # For codes with special chars: match standalone (not part of word)
          if code.match(/^\w+$/)
            # Simple word-only code: use word boundaries
            pattern = /\b#{escaped_code}\b/
          else
            # Code with special characters: match standalone
            # Use negative lookbehind/lookahead to ensure not part of word
            # This works for codes like "(7TV)" - matches when not surrounded by word chars
            pattern = /(?<!\w)#{escaped_code}(?!\w)/
          end
          
          replacement = "[emote|#{emote.url}|#{code}]"
          
          # Perform replacement
          result = result.gsub(pattern, replacement)
        end
      end

      result
    end
  end
end

