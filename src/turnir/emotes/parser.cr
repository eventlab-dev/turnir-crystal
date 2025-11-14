require "./types"

module Turnir::Emotes
  # Emote parser for converting emote codes to [emote|URL|NAME] format in messages
  class Parser

    # Parse message and replace emote codes with [emote|URL|NAME] format
    # For Twitch: replaces emote codes like "Kappa" with "[emote|https://...|Kappa]"
    def self.parse_twitch_message(text : String, user_slug : String?) : String
      return text if text.empty?


      # Get emotes from memory
      emotes = Emotes.get_emotes("twitch", user_slug)
      
      # Debug: log emote count first time
      if emotes.empty?
        puts "Parser: No emotes found for user '#{user_slug || "global"}'"
        return text
      end

      # Sort by length (longest first) to avoid partial matches
      sorted_codes = emotes.keys.sort_by { |k| -k.size }

      result = text

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
        
        # Check if pattern matches before replacement (for debug)
        matched = result.match(pattern)
        
        # Perform replacement
        result = result.gsub(pattern, replacement)
      end


      result
    end
  end
end

