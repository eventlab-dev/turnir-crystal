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

      unless text.valid_encoding?
        return text
      end

      result = text

      begin
        if !irc_emotes.empty?
          irc_emotes.each do |emote_id, emote_code|
            next unless emote_code.valid_encoding?
            
            emote_url = "https://static-cdn.jtvnw.net/emoticons/v2/#{emote_id}/default/dark/2.0"
            
            begin
              escaped_code = Regex.escape(emote_code)
              pattern = /(^|\s)#{escaped_code}(?=\s|$)/
              replacement = "\\1[emote|#{emote_url}|#{emote_code}]"
              result = result.gsub(pattern, replacement)
            rescue ex
              next
            end
          end
        end

        emotes = Emotes.get_emotes("twitch", user_slug)
        
        if !emotes.empty?
          sorted_codes = emotes.keys.sort_by { |k| -k.size }

          sorted_codes.each do |code|
            next unless code.valid_encoding?
            
            emote = emotes[code]
            
            begin
              escaped_code = Regex.escape(code)
              pattern = /(^|\s)#{escaped_code}(?=\s|$)/
              
              replacement = if emote.is_zero_width
                "\\1[emote|#{emote.url}|#{code}|zw]"
              else
                "\\1[emote|#{emote.url}|#{code}]"
              end
              
              result = result.gsub(pattern, replacement)
            rescue ex
              next
            end
          end
        end
      rescue ex
        return text
      end

      result
    end
  end
end






