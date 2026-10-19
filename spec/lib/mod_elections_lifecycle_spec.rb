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

  def member
    Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago)
  end

  # One seat and a second candidate beside the sitting moderator: with no
  # more candidates than seats there's nothing to vote on, so no Vote Week.
  def contest!
    election.update!(seats: 1)
    DiscourseModElections::Nominations.run!(member, election, "")
  end

  def election_notes(user)
    Notification
      .where(user_id: user.id, notification_type: Notification.types[:custom])
      .order(:id)
      .map { |n| JSON.parse(n.data) }
      .select { |d| d["mod_election"] }
      .map { |d| d["mod_election_kind"] }
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
    expect(DiscourseModElections::Voter.find_by(election: election, user: tl1).weight).to eq(1)
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
    contest!
    tick_at(2027, 1, 8, 0, 5)
    expect(election).to be_voting

    # Both could have run, so they were told when nominations opened.
    expect(election_notes(voter)).to eq(%w[can_run voting_open])

    DiscourseModElections::Voting.cast!(voted, election, [election.candidates.first.id])

    tick_at(2027, 1, 14, 1)
    expect(election.reminder_sent_at).to be_present
    expect(election_notes(voter)).to eq(%w[can_run voting_open reminder])
    expect(election_notes(voted)).to eq(%w[can_run voting_open])

    tick_at(2027, 1, 15, 0, 5)
    expect(election).to be_closed
    expect(election).not_to be_vote_skipped
    expect(election.seed).to be_present
    expect(election_notes(admin)).to eq(%w[closed])
  end

  describe "with no more candidates than seats" do
    before { Jobs.run_immediately! }

    it "keeps nominations open longer, once, then has no Vote Week" do
      voter = member
      tick_at(2027, 1, 1, 0, 5)

      messages =
        MessageBus.track_publish(DiscourseModElections::State::CHANNEL) do
          tick_at(2027, 1, 8, 0, 5)
        end
      expect(messages.size).to eq(1)
      expect(election).to be_nominating
      expect(election).to be_nominations_extended
      expect(election.voting_open_at).to eq_time(zone.local(2027, 1, 11))
      expect(election.voting_close_at).to eq_time(zone.local(2027, 1, 18))
      expect(DiscourseModElections::State.active).to include(extended: true)
      expect(election_notes(voter)).to eq(%w[can_run nominations_extended])

      tick_at(2027, 1, 11, 0, 5)
      expect(election).to be_closed
      expect(election).to be_vote_skipped
      expect(election.voting_close_at).to eq_time(zone.local(2027, 1, 11))
      expect(election.seed).to be_present
      # Nobody is told to vote when there's nothing to vote on.
      expect(election_notes(voter)).to eq(%w[can_run nominations_extended])
      expect(election_notes(admin)).to eq(%w[vote_skipped])

      DiscourseModElections::Publisher.publish!(election, admin)
      expect(election.reload.result["outcome"]).to eq("unopposed")
      expect(election.candidates.find_by(user: moderator)).to be_elected
      expect(moderator.reload).to be_moderator
    end

    it "opens Vote Week as usual when enough people run in the extra days" do
      tick_at(2027, 1, 1, 0, 5)
      tick_at(2027, 1, 8, 0, 5)
      3.times { DiscourseModElections::Nominations.run!(member, election, "") }

      tick_at(2027, 1, 11, 0, 5)
      expect(election).to be_voting
      expect(election).not_to be_vote_skipped
      expect(election.voting_close_at).to eq_time(zone.local(2027, 1, 18))
    end

    it "has no Vote Week straight away when there are no extra days" do
      SiteSetting.mod_elections_nomination_extension_days = 0
      tick_at(2027, 1, 1, 0, 5)
      tick_at(2027, 1, 8, 0, 5)

      expect(election).to be_closed
      expect(election).to be_vote_skipped
      expect(election).not_to be_nominations_extended
    end

    it "doesn't keep nominations open when the extra days would be over already" do
      tick_at(2027, 1, 1, 0, 5)
      # Nothing moved it on in time (the module was off, say).
      tick_at(2027, 1, 12)

      expect(election).to be_vote_skipped
      expect(election).not_to be_nominations_extended
    end

    it "never keeps open nominations an admin closed early" do
      tick_at(2027, 1, 2)
      described_class.end_phase!(election, admin)

      expect(election).to be_closed
      expect(election).to be_vote_skipped
      expect(election).not_to be_nominations_extended
    end

    it "says so in the election's topic" do
      SiteSetting.mod_elections_category = Fabricate(:category).id.to_s
      tick_at(2027, 1, 1, 0, 5)
      topic = election.topic

      tick_at(2027, 1, 8, 0, 5)
      expect(topic.posts.last.raw).to include("Nominations stay open until")

      tick_at(2027, 1, 11, 0, 5)
      raw = topic.posts.last.raw
      expect(raw).to include("there's no Vote Week")
      expect(raw).to include("/u/#{moderator.username}")
      expect(raw).not_to include("@#{moderator.username}")
    end
  end

  describe "inviting members to run" do
    before { Jobs.run_immediately! }

    def notified(kind)
      Notification
        .where(notification_type: Notification.types[:custom])
        .map { |n| [n.user_id, JSON.parse(n.data)] }
        .select { |_, data| data["mod_election_kind"] == kind }
        .map(&:first)
    end

    it "tells everyone who can run, and only them, when nominations open and when they're kept open" do
      freeze_time(zone.local(2027, 1, 1, 0, 5))
      can = member
      punished_by_mod = member
      UserHistory.create!(
        action: UserHistory.actions[:silence_user],
        acting_user: moderator,
        target_user: punished_by_mod,
      )
      tl1 = Fabricate(:user, trust_level: TrustLevel[1], created_at: 1.year.ago)
      too_new = Fabricate(:user, trust_level: TrustLevel[2], created_at: 10.days.ago)
      punished = member
      UserHistory.create!(
        action: UserHistory.actions[:suspend_user],
        acting_user: admin,
        target_user: punished,
      )
      suspended = member
      suspended.update!(suspended_till: 1.month.from_now, suspended_at: Time.zone.now)
      staged = Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago, staged: true)

      described_class.tick
      expect(notified("can_run")).to contain_exactly(can.id, punished_by_mod.id)
      # The sitting moderator is told they're on the ballot instead.
      expect(notified("on_ballot")).to eq([moderator.id])

      # The same rules as running.
      [can, punished_by_mod, tl1, too_new, punished, suspended, staged, admin].each do |user|
        blocked = DiscourseModElections::Eligibility.run_blocked_reason(user, election)
        expect(notified("can_run").include?(user.id)).to eq(blocked.nil?)
      end

      # Someone who ran in the meantime isn't asked again.
      DiscourseModElections::Nominations.run!(punished_by_mod, election, "")
      DiscourseModElections::Nominations.withdraw!(punished_by_mod, election)
      tick_at(2027, 1, 8, 0, 5)
      expect(election).to be_nominations_extended
      expect(notified("nominations_extended")).to eq([can.id])
    end

    it "tells nobody but the sitting moderators when switched off" do
      SiteSetting.mod_elections_invite_candidates = false
      member
      tick_at(2027, 1, 1, 0, 5)
      tick_at(2027, 1, 8, 0, 5)

      expect(notified("can_run")).to be_empty
      expect(notified("nominations_extended")).to be_empty
      expect(notified("on_ballot")).to eq([moderator.id])
    end
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

    contest!
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
      contest!
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
    contest!
    tick_at(2027, 1, 8, 0, 5)

    expect(election).to be_voting
  end

  describe "the reminder" do
    it "never comes in Vote Week's first day" do
      SiteSetting.mod_elections_voting_days = 1
      tick_at(2027, 1, 1, 0, 5)
      contest!
      tick_at(2027, 1, 8, 0, 5)
      tick_at(2027, 1, 8, 12)

      expect(election).to be_voting
      expect(election.reminder_sent_at).to be_nil
    end

    it "comes a day before the end of a longer Vote Week" do
      SiteSetting.mod_elections_voting_days = 2
      tick_at(2027, 1, 1, 0, 5)
      contest!
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

  it "tells admins once when an unfinished election keeps the next one from starting" do
    tick_at(2027, 1, 1, 0, 5)
    january = election
    contest!
    described_class.end_phase!(january, admin)
    described_class.end_phase!(january, admin)
    expect(january.reload).to be_closed

    # Nobody publishes or cancels January's before April's nominations.
    tick_at(2027, 4, 1, 0, 5)
    tick_at(2027, 4, 2)
    expect(DiscourseModElections::Election.count).to eq(1)

    notes =
      Notification
        .where(user: admin)
        .map { |n| JSON.parse(n.data) }
        .select { |data| data["mod_election_kind"] == "schedule_blocked" }
    expect(notes.size).to eq(1)
    expect(notes.sole).to include(
      "mod_election_id" => january.id,
      "url" => "/admin/plugins/jtech-tools/mod-elections",
    )
  end

  describe ".end_phase!" do
    it "lets an admin end nominations and Vote Week early" do
      tick_at(2027, 1, 2)
      contest!
      described_class.end_phase!(election, admin)
      expect(election.reload).to be_voting

      described_class.end_phase!(election, admin)
      expect(election.reload).to be_closed
    end
  end

  describe ".update!" do
    def edit!(**wanted)
      described_class.update!(election, admin, **wanted)
    end

    def refused(reason)
      raise_error(DiscourseModElections::Error) { |e| expect(e.reason).to eq(reason) }
    end

    it "changes the seats and the dates still ahead, and tells everyone" do
      SiteSetting.mod_elections_category = Fabricate(:category).id.to_s
      tick_at(2027, 1, 2)

      messages =
        MessageBus.track_publish(DiscourseModElections::State::CHANNEL) do
          edit!(
            seats: 5,
            voting_open_at: zone.local(2027, 1, 10),
            voting_close_at: zone.local(2027, 1, 20),
          )
        end
      expect(messages.size).to eq(1)
      expect(election.seats).to eq(5)
      expect(election.voting_open_at).to eq_time(zone.local(2027, 1, 10))
      expect(election.voting_close_at).to eq_time(zone.local(2027, 1, 20))
      log = UserHistory.find_by(custom_type: "mod_election_edit", acting_user_id: admin.id)
      expect(log.details).to include("seats: 5")
      expect(election.topic.posts.last.raw).to include("5 seats")

      # The new dates are the ones the calendar follows.
      tick_at(2027, 1, 8, 0, 5)
      expect(election).to be_nominating
    end

    it "changes only what's still ahead in each phase, and nothing once voting has closed" do
      tick_at(2027, 1, 2)
      expect { edit!(nominations_open_at: zone.local(2027, 1, 3)) }.to refused(:not_editable)

      contest!
      tick_at(2027, 1, 8, 0, 5)
      expect(election).to be_voting
      expect { edit!(voting_open_at: zone.local(2027, 1, 9)) }.to refused(:not_editable)
      edit!(seats: 2, voting_close_at: zone.local(2027, 1, 16))
      expect(election.seats).to eq(2)

      tick_at(2027, 1, 16, 0, 5)
      expect(election).to be_closed
      # More or fewer seats now would change who the ballots elect.
      expect { edit!(seats: 3) }.to refused(:edit_closed)
      expect(election.reload.seats).to eq(2)
    end

    it "treats a deadline that has passed as passed, even before the tick moves it on" do
      tick_at(2027, 1, 1, 0, 5)
      contest!

      freeze_time(zone.local(2027, 1, 8, 0, 1))
      expect(election).to be_nominating
      expect { edit!(voting_open_at: zone.local(2027, 1, 10)) }.to refused(:not_editable)
      expect(election.reload).to be_voting

      freeze_time(zone.local(2027, 1, 15, 0, 1))
      expect { edit!(voting_close_at: zone.local(2027, 1, 20)) }.to refused(:edit_closed)
      expect(election.reload).to be_closed
      expect(election.voting_close_at).to eq_time(zone.local(2027, 1, 15))
    end

    it "refuses dates in the past or out of order, and seats that aren't a number of seats" do
      tick_at(2027, 1, 2)
      expect { edit!(voting_open_at: zone.local(2027, 1, 1, 12)) }.to refused(:edit_in_past)
      expect { edit!(voting_open_at: zone.local(2027, 1, 20)) }.to refused(:invalid_dates)
      expect { edit!(seats: 0) }.to refused(:invalid_seats)

      election.reload
      expect(election.seats).to eq(3)
      expect(election.voting_open_at).to eq_time(zone.local(2027, 1, 8))
    end

    it "logs and announces nothing when nothing is different" do
      tick_at(2027, 1, 2)
      expect { edit!(seats: election.seats, voting_open_at: election.voting_open_at) }.not_to(
        change { UserHistory.where(custom_type: "mod_election_edit").count },
      )
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

    it "refuses one whose Vote Week has already begun" do
      freeze_time
      expect {
        described_class.create!(
          admin,
          seats: 2,
          nominations_open_at: 1.year.ago,
          voting_open_at: 1.year.ago + 3.days,
          voting_close_at: 1.year.ago + 6.days,
        )
      }.to raise_error(DiscourseModElections::Error) { |e| expect(e.reason).to eq(:dates_in_past) }
      expect(DiscourseModElections::Election.count).to eq(0)
    end
  end
end
