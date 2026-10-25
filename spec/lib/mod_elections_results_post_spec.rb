# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseModElections::ResultsPost do
  fab!(:admin)
  fab!(:category)
  # Old enough to run: publishing first takes anyone who can't off the ballot.
  fab!(:alice) do
    Fabricate(:user, username: "alice_k", trust_level: TrustLevel[2], created_at: 1.year.ago)
  end
  fab!(:bob) do
    Fabricate(:user, username: "bob_m", trust_level: TrustLevel[2], created_at: 1.year.ago)
  end
  fab!(:carol) do
    Fabricate(:user, username: "carol_z", trust_level: TrustLevel[2], created_at: 1.year.ago)
  end
  fab!(:voter) { Fabricate(:user, username: "quiet_voter", trust_level: TrustLevel[3]) }

  let(:election) do
    DiscourseModElections::Election.create!(
      status: :closed,
      seats: 1,
      nominations_open_at: 15.days.ago,
      voting_open_at: 8.days.ago,
      voting_close_at: 1.hour.ago,
      seed: 1,
    )
  end
  let!(:c_alice) { candidate(alice) }
  let!(:c_bob) { candidate(bob) }
  let!(:c_carol) { candidate(carol) }

  def candidate(user)
    DiscourseModElections::Candidate.create!(election: election, user: user)
  end

  def ballot(user, weight, *ranked)
    DiscourseModElections::Ballot.create!(
      election: election,
      user: user,
      weight: weight,
      ranking: ranked.map(&:id),
    )
  end

  def results_post
    Post
      .where(topic_id: election.reload.topic_id, user_id: Discourse::SYSTEM_USER_ID)
      .order(:post_number)
      .last
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mod_elections_enabled = true
    SiteSetting.mod_elections_category = category.id.to_s
    DiscourseModElections::Announcer.nominations_open(election)
    # Alice 3 + 1 from Carol's transfer, Bob 3, Carol 1 and out first.
    ballot(voter, 3, c_alice)
    ballot(Fabricate(:user), 3, c_bob)
    ballot(Fabricate(:user), 1, c_carol, c_alice)
  end

  it "charts the whole count when results are published, and names no voter" do
    DiscourseModElections::Publisher.publish!(election, admin)

    raw = results_post.raw
    expect(raw).to include("The results are in. Elected:\n- [alice_k]")
    expect(raw).to include("[wrap=mod-election-count]")
    expect(raw).to include("Ballots counted: **3**, worth **7 votes**")
    # First choices: everyone's share of the 7 votes, with a bar.
    expect(raw).to match(/\| \[alice_k\]\([^)]+\) \| 3 \| 42\.9% \| █+/)
    expect(raw).to match(/\| \[carol_z\]\([^)]+\) \| 1 \| 14\.3% \| █/)
    expect(raw).to include("carol_z is out.")
    expect(raw).to include("Elected: [alice_k]")
    expect(raw).to include("Out at stage 2")
    expect(raw).to include("[details=\"Every stage in numbers\"]")
    expect(raw).to include("/elections?id=#{election.id})")
    expect(raw).not_to include("quiet_voter")
    expect(results_post.cooked).to include("data-wrap=\"mod-election-count\"")
  end

  it "charts past elections' results in the post they already have, once" do
    DiscourseModElections::Publisher.publish!(election, admin)
    old = results_post
    old.revise(
      Discourse.system_user,
      { raw: "The results are in.\n\n[Every stage of the count](/elections?id=#{election.id})" },
      skip_validations: true,
    )
    PluginStore.remove(described_class::STORE, described_class::DONE_KEY)
    bumped_at = election.topic.reload.bumped_at
    posts = election.topic.posts.count

    DiscourseModElections::Lifecycle.tick

    expect(old.reload.raw).to include("[wrap=mod-election-count]")
    expect(election.topic.posts.count).to eq(posts)
    expect(election.topic.reload.bumped_at).to eq_time(bumped_at)

    version = old.reload.version
    DiscourseModElections::Lifecycle.tick
    expect(old.reload.version).to eq(version)
  end

  it "adds the post when a past election's topic has none, and waits while the module is off" do
    DiscourseModElections::Tally
      .count(election)
      .then { |result| DiscourseModElections::Tally.serialize(election, result) }
      .then do |result|
        election.update!(status: :published, result: result, published_at: Time.zone.now)
      end
    posts = election.topic.posts.count

    SiteSetting.mod_elections_enabled = false
    DiscourseModElections::Lifecycle.tick
    expect(election.topic.posts.count).to eq(posts)

    SiteSetting.mod_elections_enabled = true
    DiscourseModElections::Lifecycle.tick
    expect(election.topic.posts.count).to eq(posts + 1)
    expect(results_post.raw).to include("How the count went")
  end

  it "says when nobody voted because nominations were uncontested" do
    election.ballots.delete_all
    c_carol.update!(status: :withdrawn)
    c_bob.update!(status: :withdrawn)
    election.update!(vote_skipped_at: election.voting_open_at)

    DiscourseModElections::Publisher.publish!(election, admin)

    raw = results_post.raw
    expect(raw).to include("Elected unopposed:\n- [alice_k]")
    expect(raw).not_to include("How the count went")
  end
end
