# frozen_string_literal: true

class CreateJtechAdVotes < ActiveRecord::Migration[7.2]
  def change
    create_table :jtech_ad_votes do |t|
      t.integer :user_id, null: false
      t.string :ad_key, null: false, limit: 12
      t.integer :value, null: false, limit: 2
      t.timestamps
    end

    add_index :jtech_ad_votes, %i[user_id ad_key], unique: true
    add_index :jtech_ad_votes, :ad_key
  end
end
