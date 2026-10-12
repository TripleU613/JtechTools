# frozen_string_literal: true

module DiscourseModElections
  # One voter's ranking. Never shown to anyone but its voter; admins see only
  # that a ballot exists when they check for alt accounts. When results are
  # published it loses its user and address, so no ballot says whose it was.
  class Ballot < ActiveRecord::Base
    self.table_name = "jtech_election_ballots"

    belongs_to :election, class_name: "DiscourseModElections::Election"
    belongs_to :user, optional: true
    belongs_to :voided_by, class_name: "User", optional: true

    scope :counted, -> { where(voided_at: nil) }

    def voided?
      voided_at.present?
    end
  end
end

# == Schema Information
#
# Table name: jtech_election_ballots
#
#  id           :bigint           not null, primary key
#  ip_address   :inet
#  ranking      :bigint           default([]), not null, is an Array
#  void_reason  :text
#  voided_at    :datetime
#  weight       :integer          not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#  election_id  :bigint           not null
#  user_id      :bigint
#  voided_by_id :bigint
#
# Indexes
#
#  index_jtech_election_ballots_on_election_id_and_user_id  (election_id,user_id) UNIQUE
#  index_jtech_election_ballots_on_user_id                  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (election_id => jtech_elections.id) ON DELETE => cascade
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
