# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseModElections::Notifier do
  fab!(:alice) { Fabricate(:user, trust_level: TrustLevel[1]) }
  fab!(:bob) { Fabricate(:user, trust_level: TrustLevel[1]) }

  let(:election) do
    DiscourseModElections::Election.create!(
      status: :voting,
      seats: 3,
      nominations_open_at: 8.days.ago,
      voting_open_at: 1.day.ago,
      voting_close_at: 6.days.from_now,
    )
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mod_elections_enabled = true
  end

  def election_notes(user)
    Notification
      .where(user_id: user.id, notification_type: Notification.types[:custom])
      .map { |n| JSON.parse(n.data) }
      .select { |d| d["mod_election"] }
  end

  it "says which step it is and links to the page, nothing about any ballot" do
    described_class.notify([alice.id], election, "voting_open")

    note = election_notes(alice).sole
    expect(note).to include(
      "mod_election_kind" => "voting_open",
      "mod_election_id" => election.id,
      "url" => "/elections",
    )
    expect(note.keys).not_to include("ranking")
  end

  it "doesn't send anyone the same step twice when a job is retried" do
    described_class.notify([alice.id], election, "voting_open")
    described_class.notify([alice.id, bob.id], election, "voting_open")

    expect(election_notes(alice).size).to eq(1)
    expect(election_notes(bob).size).to eq(1)
  end

  it "keeps steps of different elections apart" do
    other = election.dup.tap { |e| e.update!(status: :cancelled) }
    described_class.notify([alice.id], other, "voting_open")
    described_class.notify([alice.id], election, "voting_open")

    expect(election_notes(alice).map { |n| n["mod_election_id"] }).to contain_exactly(
      other.id,
      election.id,
    )
  end

  it "tells a candidate each time they're taken off the ballot" do
    2.times { described_class.notify([alice.id], election, "disqualified") }
    expect(election_notes(alice).size).to eq(2)
  end

  it "reminds only voters who haven't voted" do
    candidate = DiscourseModElections::Candidate.create!(election: election, user: bob)
    [alice, bob].each do |user|
      DiscourseModElections::Voter.create!(election: election, user: user, weight: 2)
    end
    DiscourseModElections::Ballot.create!(
      election: election,
      user: bob,
      weight: 2,
      ranking: [candidate.id],
    )
    # A deleted voter's ballot, kept without its user, must not hide
    # everyone else from the reminder.
    DiscourseModElections::Ballot.create!(election: election, weight: 1, ranking: [candidate.id])

    expect(described_class.voter_ids(election, "reminder")).to eq([alice.id])
  end
end

RSpec.describe DiscourseModElections::Disteleplus do
  fab!(:winner) { Fabricate(:user, username: "chaim_w") }

  let(:election) do
    DiscourseModElections::Election
      .create!(
        status: :published,
        seats: 1,
        nominations_open_at: 15.days.ago,
        voting_open_at: 8.days.ago,
        voting_close_at: 1.day.ago,
      )
      .tap do |election|
        candidate = election.candidates.create!(user: winner, elected: true)
        election.update!(result: { "elected" => [candidate.id] })
      end
  end

  it "tells the staff Telegram topic who won, once" do
    described_class.stubs(:available?).returns(true)
    described_class
      .expects(:send_html)
      .with do |html, dedupe_key:|
        html.include?("chaim_w") && html.include?("/elections?id=#{election.id}") &&
          dedupe_key == "mod-election-#{election.id}-results"
      end
      .once

    described_class.results(election)
  end

  it "stays quiet when Disteleplus isn't sending admin notices" do
    described_class.stubs(:available?).returns(false)
    described_class.expects(:send_html).never

    described_class.results(election)
    described_class.closed(election)
    described_class.vote_skipped(election)
  end

  it "says nothing about the count before it's published" do
    election.update!(status: :closed, result: nil)
    3.times { DiscourseModElections::Ballot.create!(election: election, weight: 1, ranking: [7]) }
    described_class.stubs(:available?).returns(true)
    described_class
      .expects(:send_html)
      .with do |html, dedupe_key:|
        html.include?("/admin/plugins/jtech-tools/mod-elections") && !html.include?("3") &&
          dedupe_key == "mod-election-#{election.id}-closed"
      end
      .once

    described_class.closed(election)
  end

  it "tells staff when there's no Vote Week, so they publish" do
    election.update!(status: :closed, result: nil, vote_skipped_at: Time.zone.now)
    described_class.stubs(:available?).returns(true)
    described_class
      .expects(:send_html)
      .with do |html, dedupe_key:|
        html.include?("no Vote Week") &&
          html.include?("/admin/plugins/jtech-tools/mod-elections") &&
          dedupe_key == "mod-election-#{election.id}-vote_skipped"
      end
      .once

    described_class.vote_skipped(election)
  end

  it "names winners as their accounts are now" do
    winner.update_column(:username, "renamed_w")
    described_class.stubs(:available?).returns(true)
    described_class.expects(:send_html).with { |html, **| html.include?("renamed_w") }.once

    described_class.results(election)
  end

  it "escapes what it puts in Telegram's HTML" do
    winner.update_column(:username, "<b>x</b>")
    described_class.stubs(:available?).returns(true)
    described_class
      .expects(:send_html)
      .with { |html, **| html.include?("&lt;b&gt;x&lt;/b&gt;") }
      .once

    described_class.results(election)
  end
end
