require "./message"

module Turnir::ChatStorage
  extend self

  class Storage
    property storage : Array(Turnir::ChatStorage::Types::ChatMessage)
    property storage_mutex : Mutex
    property last_access : Time

    MESSAGES_LIMIT = 5000

    def initialize
      @storage = [] of Turnir::ChatStorage::Types::ChatMessage
      @storage_mutex = Mutex.new
      @last_access = Time.utc
    end

    def add_message(msg : Turnir::ChatStorage::Types::ChatMessage)
      if msg.message.includes?("@badge-info=") || msg.message.includes?("PRIVMSG")
        puts "[STORAGE ERROR] Raw IRC detected when adding to storage!"
        puts "  Channel: #{msg.channel}"
        puts "  Username: #{msg.user.username}"
        puts "  Message: #{msg.message[0..200]}"
      end

      @storage_mutex.synchronize do
        @storage << msg
        if @storage.size > MESSAGES_LIMIT
          @storage.shift
        end
      end
    end

    def get_messages(channel : String, since : Int64, text_filter : String)
      # puts "Fetching messages for #{channel}"
      # puts "Messages: #{Storage.size}"
      @storage_mutex.synchronize do
        @storage.select { |msg| msg.channel == channel && msg.ts >= since && msg.message.downcase.includes?(text_filter) }
      end
    end

    def clear
      @storage_mutex.synchronize do
        @storage.clear
      end
    end

    def should_stop?
      (@last_access + @stop_timeout) < Time.utc
    end

    def get_last_message_ts(channel : String) : Int64
      @storage_mutex.synchronize do
        last_message = @storage.reverse.find { |msg| msg.channel == channel }
        if last_message
          last_message.ts
        else
          0_i64
        end
      end
    end

    def get_last_messages(channel : String, count : Int)
      @storage_mutex.synchronize do
        @storage.select { |msg| msg.channel == channel }.last(count)
      end
    end
  end
end
