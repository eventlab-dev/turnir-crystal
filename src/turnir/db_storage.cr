require "mysql"
require "db"
require "./config"

module Turnir::DbStorage
  extend self

  DB = ::DB.open(Turnir::Config.database_url)

  def create_tables
    DB.exec(
      "CREATE TABLE IF NOT EXISTS chat_messages (" \
      "id BIGINT AUTO_INCREMENT PRIMARY KEY," \
      "created_at INT NOT NULL," \
      "message TEXT NOT NULL," \
      "username VARCHAR(255) NOT NULL," \
      "chat_name VARCHAR(255) NOT NULL" \
      ") ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci"
    )
    
  end

  def save_message(created_at : Int32, message : String, username : String, chat_name : String)
    DB.exec(
      "INSERT INTO chat_messages (created_at, message, username, chat_name) VALUES (?, ?, ?, ?)",
      created_at, message, username, chat_name
    )
  end

  def delete_old_messages(older_than : Int32)
    DB.exec(
      "DELETE FROM chat_messages WHERE created_at < ?",
      older_than
    )
  end
end
