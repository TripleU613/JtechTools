# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseModElections::Lifecycle do
  let(:zone) { ActiveSupport::TimeZone["America/New_York"] }

  fab!(:moderator) { Fabricate(:moderator, trust_level: TrustLevel[3], created_at: 1.year.ago) }
  fab!(:admin) { Fabricate(:admin, created_at: 1.year.ago) }

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mod_elections_enabled = true
    SiteSetting.mod_elections_timezone = "America/New_York"
  end

  def election
    DiscourseModElections::Election.last
  end

  def tick_at(*local)
    freeze_time(zone.local(*local))
    described_class.tick
  end

  it "does nothing while switched off" do
    SiteSetting.mod_elections_enabled = false
    tick_at(2027, 1, 1, 0, 5)
    expect(DiscourseModElections::Election.count).to eq(0)

    SiteSetting.mod_elections_enabled = true
    SiteSetting.jtech_enabled = false
    tick_at(2027, 1, 1, 0, 5)
    expect(DiscourseModElections::Election.count).to eq(0)
  end

  it "opens nominations at midnight on the 1st of a scheduled month" do
    tick_at(2026, 12, 31, 23, 55)
    expect(DiscourseModElections::Election.count).to eq(0)

    tick_at(2027, 1, 1, 0, 5)
    expect(election).to be_nominating
    expect(election.seats).to eq(3)
    expect(election.nominations_open_at).to eq_time(zone.local(2027, 1, 1))
    expect(election.voting_open_at).to eq_time(zone.local(2027, 1, 8))
    expect(election.voting_close_at).to eq_time(zone.local(2027, 1, 15))
  end

  it "keeps midnight across a clock change" do
    SiteSetting.mod_elections_schedule_months = "3"
    tick_at(2027, 3, 1, 9)
    # Clocks go forward on March 14, 2027 in New York.
    expect(election.voting_close_at).to eq_time(zone.local(2027, 3, 15))
  end

  it "still opens late in the nomination week, but never skips straight to Vote Week" do
    tick_at(2027, 1, 9, 12)
    expect(DiscourseModElections::Election.count).to eq(0)

    tick_at(2027, 1, 5, 12)
    expect(election).to be_nominating
  end

  it "leaves other months alone" do
    tick_at(2027, 2, 1, 12)
    expect(DiscourseModElections::Election.count).to eq(0)
  end

  it "fixes the voter list when nominations open, weighted by trust level" do
    freeze_time(zone.local(2027, 1, 1, 0, 5))
    old = 40.days.ago
    tl1 = Fabricate(:user, trust_level: TrustLevel[1], created_at: old)
    tl3 = Fabricate(:user, trust_level: TrustLevel[3], created_at: old)
    tl0 = Fabricate(:user, trust_level: TrustLevel[0], created_at: old)
    too_new = Fabricate(:user, trust_level: TrustLevel[2], created_at: 10.days.ago)
    suspended =
      Fabricate(:user, trust_level: TrustLevel[2], created_at: old, suspended_till: 1.day.from_now)
    silenced =
      Fabricate(:user, trust_level: TrustLevel[2], created_at: old, silenced_till: 1.day.from_now)
    staged = Fabricate(:user, trust_level: TrustLevel[2], created_at: old, staged: true)

    described_class.tick

    roll =
      DiscourseModElections::Voter.where(election_id: election.id).pluck(:user_id, :weight).to_h
    expect(roll).to include(tl1.id => 1, tl3.id => 3, moderator.id => 3)
    expect(roll.keys).not_to include(
      tl0.id,
      too_new.id,
      suspended.id,
      silenced.id,
      staged.id,
      admin.id,
    )

    # Levelling up during the election changes nothing.
    tl1.change_trust_level!(TrustLevel[4])
    expect(DiscourseModElections::Roll.weight_for(election, tl1)).to eq(1)
  end

  it "puts the sitting moderators on the ballot and tells them" do
    admin.update!(moderator: true)

    tick_at(2027, 1, 1, 0, 5)

    candidates = election.candidates.to_a
    expect(candidates.map(&:user_id)).to eq([moderator.id])
    expect(candidates.first).to be_incumbent
    expect(candidates.first).to be_running
    note =
      Notification.where(user_id: moderator.id, notification_type: Notification.types[:custom]).last
    expect(JSON.parse(note.data)).to include("mod_election_kind" => "on_ballot")
  end

  it "opens Vote Week, reminds those who haven't voted, then closes for the count" do
    Jobs.run_immediately!
    voter = Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago)
    voted = Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago)

    tick_at(2027, 1, 1, 0, 5)
    tick_at(2027, 1, 8, 0, 5)
    expect(election).to be_voting

    election_notes = ->(user) do
      Notification
        .where(user_id: user.id, notification_type: Notification.types[:custom])
        .map { |n| JSON.parse(n.data) }
        .select { |d| d["mod_election"] }
        .map { |d| d["mod_election_kind"] }
    end
    expect(election_notes.call(voter)).to eq(%w[voting_open])

    DiscourseModElections::Voting.cast!(voted, election, [election.candidates.first.id])

    tick_at(2027, 1, 14, 1)
    expect(election.reminder_sent_at).to be_present
    expect(election_notes.call(voter)).to eq(%w[voting_open reminder])
    expect(election_notes.call(voted)).to eq(%w[voting_open])

    tick_at(2027, 1, 15, 0, 5)
    expect(election).to be_closed
    expect(election.seed).to be_present
    expect(election_notes.call(admin)).to eq(%w[closed])
  end

  it "tells open elections pages when a step changes, and only signed-in members" do
    channel = DiscourseModElections::State::CHANNEL
    messages = MessageBus.track_publish(channel) { tick_at(2027, 1, 1, 0, 5) }
    expect(messages.size).to eq(1)
    expect(messages.first.group_ids).to eq([Group::AUTO_GROUPS[:trust_level_0]])
    expect(messages.first.data).to eq(changed: true)

    expect(MessageBus.track_publish(channel) { tick_at(2027, 1, 2) }).to be_empty
  end

  it "doesn't bring back an election an admin cancelled" do
    tick_at(2027, 1, 1, 0, 5)
    DiscourseModElections::Publisher.cancel!(election, admin)

    tick_at(2027, 1, 2)
    expect(DiscourseModElections::Election.count).to eq(1)
    expect(election).to be_cancelled
  end

  it "opens a topic in the elections category and posts each step there" do
    category = Fabricate(:category)
    SiteSetting.mod_elections_category = category.id.to_s

    tick_at(2027, 1, 1, 0, 5)
    topic = election.topic
    expect(topic.category_id).to eq(category.id)
    expect(topic.title).to include("January 2027")

    tick_at(2027, 1, 8, 0, 5)
    expect(topic.reload.posts_count).to eq(2)
    expect(topic.posts.last.raw).to include("/u/#{moderator.username}")
    expect(topic.posts.last.raw).not_to include("@#{moderator.username}")
  end

  describe "deadlines" do
    let(:voter) { Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago) }

    before do
      voter
      tick_at(2027, 1, 1, 0, 5)
      DiscourseModElections::Nominations.run!(
        Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago),
        election,
        "",
      )
    end

    it "turns ballots away after Vote Week ends, even before the tick moves it on" do
      tick_at(2027, 1, 8, 0, 5)
      freeze_time(zone.local(2027, 1, 15, 0, 1))
      expect(election).to be_voting

      expect {
        DiscourseModElections::Voting.cast!(voter, election, [election.candidates.first.id])
      }.to raise_error(DiscourseModElections::Error) { |e| expect(e.reason).to eq(:not_voting) }
    end

    it "turns candidates away after nominations close, even before the tick moves it on" do
      freeze_time(zone.local(2027, 1, 8, 0, 1))
      expect(election).to be_nominating

      expect {
        DiscourseModElections::Nominations.run!(
          Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago),
          election,
          "",
        )
      }.to raise_error(DiscourseModElections::Error) { |e| expect(e.reason).to eq(:not_nominating) }
    end
  end

  it "moves on even when the election's topic post fails" do
    SiteSetting.mod_elections_category = Fabricate(:category).id.to_s
    DiscourseModElections::Announcer.stubs(:voting_open).raises(ActiveRecord::StatementInvalid)

    tick_at(2027, 1, 1, 0, 5)
    tick_at(2027, 1, 8, 0, 5)

    expect(election).to be_voting
  end

  describe "the reminder" do
    it "never comes in Vote Week's first day" do
      SiteSetting.mod_elections_voting_days = 1
      tick_at(2027, 1, 1, 0, 5)
      tick_at(2027, 1, 8, 0, 5)
      tick_at(2027, 1, 8, 12)

      expect(election).to be_voting
      expect(election.reminder_sent_at).to be_nil
    end

    it "comes a day before the end of a longer Vote Week" do
      SiteSetting.mod_elections_voting_days = 2
      tick_at(2027, 1, 1, 0, 5)
      tick_at(2027, 1, 8, 0, 5)
      expect(election.reminder_sent_at).to be_nil

      tick_at(2027, 1, 9, 0, 5)
      expect(election.reminder_sent_at).to be_present
    end
  end

  it "doesn't start a second election in a month that had one, even after the time zone changes" do
    tick_at(2027, 1, 1, 0, 5)
    DiscourseModElections::Publisher.cancel!(election, admin)

    # Still January 2 in Honolulu, whose midnight on the 1st is five hours
    # after New York's: a new slot, the same month.
    SiteSetting.mod_elections_timezone = "Pacific/Honolulu"
    tick_at(2027, 1, 2, 12)

    expect(DiscourseModElections::Election.count).to eq(1)
  end

  describe ".end_phase!" do
    it "lets an admin end nominations and Vote Week early" do
      tick_at(2027, 1, 2)
      described_class.end_phase!(election, admin)
      expect(election.reload).to be_voting

      described_class.end_phase!(election, admin)
      expect(election.reload).to be_closed
    end
  end

  describe ".create!" do
    it "starts an election off the calendar, but not while another is unfinished" do
      freeze_time
      created =
        described_class.create!(
          admin,
          seats: 2,
          nominations_open_at: 1.minute.ago,
          voting_open_at: 2.days.from_now,
          voting_close_at: 4.days.from_now,
        )
      expect(created).to be_nominating

      expect {
        described_class.create!(
          admin,
          seats: 2,
          nominations_open_at: 1.minute.ago,
          voting_open_at: 2.days.from_now,
          voting_close_at: 4.days.from_now,
        )
      }.to raise_error(DiscourseModElections::Error) { |e|
        expect(e.reason).to eq(:election_in_progress)
      }
    end
  end
end
