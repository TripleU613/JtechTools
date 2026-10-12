# frozen_string_literal: true

module DiscourseModElections
  # A place on the voter roll, taken when nominations open. The weight is
  # the voter's trust level at that moment. Once results are published it
  # also holds what became of the voter's ballot (the receipt), since the
  # ballot itself no longer says whose it was.
  class Voter < ActiveRecord::Base
    self.table_name = "jtech_election_voters"

    RECEIPTS = %w[counted set_aside].freeze

    belongs_to :election, class_name: "DiscourseModElections::Election"
    belongs_to :user, optional: true
  end
end

# == Schema Information
#
# Table name: jtech_election_voters
#
#  id             :bigint           not null, primary key
#  receipt        :string(20)
#  receipt_reason :text
#  weight         :integer          not null
#  election_id    :bigint           not null
#  user_id        :bigint
#
# Indexes
#
#  index_jtech_election_voters_on_election_id_and_user_id  (election_id,user_id) UNIQUE
#  index_jtech_election_voters_on_user_id                  (user_id)
#
# Foreign Keys
#
#  fk_rails_...  (election_id => jtech_elections.id) ON DELETE => cascade
#  fk_rails_...  (user_id => users.id) ON DELETE => nullify
#
