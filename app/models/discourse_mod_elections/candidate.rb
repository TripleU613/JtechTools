# frozen_string_literal: true

module DiscourseModElections
  # Someone running in an election. Sitting moderators are added when
  # nominations open; everyone else signs up.
  class Candidate < ActiveRecord::Base
    self.table_name = "jtech_election_candidates"

    belongs_to :election, class_name: "DiscourseModElections::Election"
    belongs_to :user, optional: true
    belongs_to :disqualified_by, class_name: "User", optional: true

    enum :status, { running: 0, withdrawn: 1, disqualified: 2 }

    # Why someone left an elected seat before the next election.
    SEAT_LEFT_REASONS = %w[stepped_down removed].freeze

    validates :statement,
              length: {
                maximum: ->(_) { SiteSetting.mod_elections_statement_max_length },
              }
    validates :seat_left_reason, inclusion: { in: SEAT_LEFT_REASONS }, allow_nil: true

    # Elected and still in the seat.
    scope :seated, -> { where(elected: true, seat_left_at: nil) }
  end
end

# == Schema Information
#
# Table name: jtech_election_candidates
#
#  id                  :bigint           not null, primary key
#  disqualified_reason :text
#  elected             :boolean          default(FALSE), not null
#  incumbent           :boolean          default(FALSE), not null
#  seat_left_at        :datetime
#  seat_left_reason    :string(20)
#  statement           :text             default(""), not null
#  status              :integer          default("running"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  disqualified_by_id  :bigint
#  election_id         :bigint           not null
#  user_id             :bigint
#
# Indexes
#
#  index_jtech_election_candidates_on_election_id_and_user_id  (election_id,user_id) UNIQUE
#  index_jtech_election_candidates_on_user_id                  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (election_id => jtech_elections.id) ON DELETE => cascade
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
