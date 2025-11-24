require "mysql"
require "db"
require "./config"

module Turnir::DbStorage
  extend self

  DB = ::DB.open(Turnir::Config.database_url)

  def init_charset
    DB.exec("SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci")
    DB.exec("SET character_set_client = utf8mb4")
    DB.exec("SET character_set_connection = utf8mb4")
    DB.exec("SET character_set_results = utf8mb4")
  end

  def create_tables
    init_charset
    
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
    init_charset
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
