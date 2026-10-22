# frozen_string_literal: true

require "rails_helper"
require_relative "../../db/migrate/20261022000001_cap_election_vote_weights"

RSpec.describe CapElectionVoteWeights do
  fab!(:leader) { Fabricate(:user, trust_level: TrustLevel[4]) }

  def election(status, **attrs)
    DiscourseModElections::Election.create!(
      status: status,
      seats: 1,
      nominations_open_at: 2.weeks.ago,
      voting_open_at: 1.week.ago,
      voting_close_at: 1.day.from_now,
      **attrs,
    )
  end

  def weights(election)
    [
      DiscourseModElections::Voter.where(election: election).pick(:weight),
      DiscourseModElections::Ballot.where(election: election).pick(:weight),
    ]
  end

  it "caps an election still uncounted, and leaves a previewed or published count alone" do
    open = election(:voting)
    previewed = election(:closed, previewed_at: 1.hour.ago)
    published = election(:published, previewed_at: 1.day.ago, published_at: 1.hour.ago)
    [open, previewed, published].each do |e|
      DiscourseModElections::Voter.create!(election: e, user: leader, weight: 4)
      DiscourseModElections::Ballot.create!(election: e, user: leader, weight: 4, ranking: [])
    end

    described_class.new.up

    expect(weights(open)).to eq([3, 3])
    expect(weights(previewed)).to eq([4, 4])
    expect(weights(published)).to eq([4, 4])
  end
end
