require "./types"
require "../parser/vk"
require "../parser/goodgame"
require "../parser/kick"

module Turnir::ChatStorage::Types
  struct ChatMessage
    include JSON::Serializable

    property id : String
    property ts : Int64
    property message : String
    property user : ChatUser
    property vk_fields : VkMessageFields | Nil
    property channel : String

    def initialize(id : String, ts : Int64, message : String, channel : String, user : ChatUser, vk_fields : VkMessageFields | Nil = nil)
      @id = id
      @ts = ts
      @message = message
      @user = user
      @vk_fields = vk_fields
      @channel = channel
    end

    def self.from_vk_message(message : Turnir::Parser::Vk::ChatMessage, text : String, mentions : Array(Turnir::Parser::Vk::ContentDataMention), channel_owner : String? = nil)
      data = message.push.pub.data.data
      # created_at = data.createdAt
      created_at = Time.utc.to_unix_ms
      message_id = data.id

      author = data.author
      username = author.displayName
      user_id = author.id

      customFields = VkUserFields.new(
        nickColor: author.nickColor,
        isChatModerator: author.isChatModerator,
        isChannelModerator: author.isChannelModerator,
        roles: author.roles,
        badges: author.badges,
      )

      user = ChatUser.new(id: user_id.to_s, username: username, vk_fields: customFields)
      vk_fields = VkMessageFields.new(mentions)
      
      formatted_channel = if channel_owner
                            "vkvideo/#{channel_owner}"
                          else
                            "vkvideo/#{message.push.channel}"
                          end
      
      new(id: message_id.to_s, ts: created_at, message: text, user: user, vk_fields: vk_fields, channel: formatted_channel)
    end

    def self.from_goodgame_message(data : Turnir::Parser::Goodgame::MessageData)
      created_at = data.timestamp * 1000
      message_id = data.message_id

      username = data.user_name
      user_id = data.user_id
      channel_id = data.channel_id
      
      formatted_channel = "goodgame/#{channel_id}"

      user = ChatUser.new(id: user_id.to_s, username: username)
      new(id: message_id.to_s, ts: created_at, message: data.text, user: user, channel: formatted_channel)
    end

    def self.from_kick_message(message : Turnir::Parser::Kick::ChatMessage)
      created_at = Time.utc.to_unix_ms
      message_id = message.message_id

      username = message.sender.username
      user_id = message.sender.user_id
      channel_slug = message.broadcaster.channel_slug
      
      formatted_channel = "kick/#{channel_slug}"

      user = ChatUser.new(id: user_id.to_s, username: username)
      new(id: message_id, ts: created_at, message: message.content, user: user, channel: formatted_channel)
    end
  end
end
