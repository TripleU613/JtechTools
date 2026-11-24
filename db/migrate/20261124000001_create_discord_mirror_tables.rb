# frozen_string_literal: true

class CreateDiscordMirrorTables < ActiveRecord::Migration[7.2]
  def change
    # One forum category ↔ one Discord forum channel. Top-level categories
    # also get a Discord channel category that groups their subcategories.
    create_table :discord_mirror_channels do |t|
      t.integer :category_id, null: false
      t.string :discord_group_id
      t.string :discord_channel_id, null: false
      t.string :webhook_id, null: false
      t.string :webhook_token, null: false
      t.timestamps
    end
    add_index :discord_mirror_channels, :category_id, unique: true

    # One topic ↔ one thread (a post in the Discord forum channel).
    create_table :discord_mirror_threads do |t|
      t.integer :topic_id, null: false
      t.integer :category_id, null: false
      t.string :discord_thread_id, null: false
      t.string :title_sent, null: false
      t.boolean :locked, null: false, default: false
      t.timestamps
    end
    add_index :discord_mirror_threads, :topic_id, unique: true

    # A forum post can need more than one Discord message (2,000-character
    # limit), so the mapping is per part.
    create_table :discord_mirror_messages do |t|
      t.integer :post_id, null: false
      t.integer :topic_id, null: false
      t.integer :part, null: false, default: 0
      t.string :discord_message_id, null: false
      t.string :content_digest, null: false
      t.integer :user_id
      t.timestamps
    end
    add_index :discord_mirror_messages, %i[post_id part], unique: true
    add_index :discord_mirror_messages, :topic_id
    add_index :discord_mirror_messages, :user_id
  end
end
