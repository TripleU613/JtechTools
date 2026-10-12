# frozen_string_literal: true

# Mod elections: the forum elects its moderators every few months, ranking
# candidates by single transferable vote with votes weighted by trust level.
class CreateJtechElectionTables < ActiveRecord::Migration[7.2]
  def change
    create_table :jtech_elections do |t|
      t.integer :status, null: false, default: 0
      t.integer :seats, null: false
      t.datetime :nominations_open_at, null: false
      t.datetime :voting_open_at, null: false
      t.datetime :voting_close_at, null: false
      # Null when the schedule created it rather than an admin.
      t.bigint :created_by_id
      t.bigint :topic_id
      t.datetime :reminder_sent_at
      # Drawn when voting closes, so the admin's preview and the published
      # count draw any lots the same way.
      t.bigint :seed
      # The published count, every stage of it, so later changes to users
      # or candidates can't rewrite what was announced.
      t.jsonb :result
      t.datetime :published_at
      t.bigint :published_by_id
      t.timestamps
    end
    add_index :jtech_elections, :status
    add_index :jtech_elections, :nominations_open_at

    create_table :jtech_election_candidates do |t|
      t.bigint :election_id, null: false
      # Kept, without the user, when an account is deleted: a published count
      # and any later countback must stay the same.
      t.bigint :user_id
      t.integer :status, null: false, default: 0
      t.text :statement, null: false, default: ""
      # A sitting moderator when nominations opened, put on the ballot
      # automatically.
      t.boolean :incumbent, null: false, default: false
      t.text :disqualified_reason
      t.bigint :disqualified_by_id
      # Set when results are published or a countback fills a seat.
      t.boolean :elected, null: false, default: false
      t.datetime :seat_left_at
      t.string :seat_left_reason, limit: 20
      t.timestamps
    end
    add_index :jtech_election_candidates, %i[election_id user_id], unique: true
    add_index :jtech_election_candidates, :user_id
    add_foreign_key :jtech_election_candidates,
                    :jtech_elections,
                    column: :election_id,
                    on_delete: :cascade
    add_foreign_key :jtech_election_candidates, :users, on_delete: :nullify

    # Who may vote and how much their vote counts, fixed when nominations
    # open so new accounts and trust level changes during the election
    # change nothing.
    create_table :jtech_election_voters do |t|
      t.bigint :election_id, null: false
      t.bigint :user_id
      t.integer :weight, null: false
    end
    add_index :jtech_election_voters, %i[election_id user_id], unique: true
    add_index :jtech_election_voters, :user_id
    add_foreign_key :jtech_election_voters,
                    :jtech_elections,
                    column: :election_id,
                    on_delete: :cascade
    add_foreign_key :jtech_election_voters, :users, on_delete: :nullify

    create_table :jtech_election_ballots do |t|
      t.bigint :election_id, null: false
      t.bigint :user_id
      # Candidate ids, best first.
      t.bigint :ranking, array: true, null: false, default: []
      t.integer :weight, null: false
      # Kept for the alt-account check until results are published, then
      # cleared.
      t.inet :ip_address
      t.datetime :voided_at
      t.bigint :voided_by_id
      t.text :void_reason
      t.timestamps
    end
    add_index :jtech_election_ballots, %i[election_id user_id], unique: true
    add_index :jtech_election_ballots, :user_id
    add_foreign_key :jtech_election_ballots,
                    :jtech_elections,
                    column: :election_id,
                    on_delete: :cascade
    add_foreign_key :jtech_election_ballots, :users, on_delete: :nullify
  end
end
