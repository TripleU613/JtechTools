# frozen_string_literal: true

require "rails_helper"

RSpec.describe DiscourseModElections::Seats do
  fab!(:admin)
  fab!(:sitting) { Fabricate(:moderator, trust_level: TrustLevel[3]) }
  fab!(:stepping_down) { Fabricate(:moderator, trust_level: TrustLevel[3]) }
  # Old enough to run: previewing and publishing take anyone who can't run
  # any more off the ballot first.
  fab!(:newcomer) { Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago) }
  fab!(:runner_up) { Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago) }
  fab!(:voter) { Fabricate(:user, trust_level: TrustLevel[3]) }

  let(:election) do
    DiscourseModElections::Election.create!(
      status: :closed,
      seats: 2,
      nominations_open_at: 15.days.ago,
      voting_open_at: 8.days.ago,
      voting_close_at: 1.hour.ago,
      seed: 1,
    )
  end

  def candidate(user, **attrs)
    DiscourseModElections::Candidate.create!(election: election, user: user, **attrs)
  end

  def ballot(user, weight, *ranked)
    DiscourseModElections::Ballot.create!(
      election: election,
      user: user,
      weight: weight,
      ranking: ranked.map(&:id),
      ip_address: "10.0.0.#{user.id % 250}",
    )
  end

  def publish
    DiscourseModElections::Publisher.publish!(election, admin)
    [sitting, stepping_down, newcomer, runner_up].each(&:reload)
  end

  def strikes(user)
    DiscourseModElections::Seats.strikes(user.reload)
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mod_elections_enabled = true
  end

  context "with a normal result" do
    let!(:c_sitting) { candidate(sitting, incumbent: true) }
    let!(:c_leaving) { candidate(stepping_down, incumbent: true, status: :withdrawn) }
    let!(:c_new) { candidate(newcomer) }
    let!(:c_runner_up) { candidate(runner_up) }

    before do
      ballot(voter, 3, c_new, c_sitting)
      ballot(Fabricate(:user), 2, c_sitting, c_new)
      ballot(Fabricate(:user), 1, c_runner_up)
    end

    it "makes the winners moderators, locked at trust level 4" do
      publish

      expect(newcomer).to be_moderator
      expect(newcomer.trust_level).to eq(TrustLevel[4])
      expect(newcomer.manual_locked_trust_level).to eq(TrustLevel[4])
      expect(sitting).to be_moderator
      expect(sitting.manual_locked_trust_level).to eq(TrustLevel[4])
      expect(runner_up).not_to be_moderator
      expect(runner_up.trust_level).to eq(TrustLevel[2])

      expect(election.reload).to be_published
      expect(election.result["elected"]).to contain_exactly(c_new.id, c_sitting.id)
      expect(election.result["stages"]).to be_present
      expect(
        UserHistory.where(action: UserHistory.actions[:grant_moderation]).pluck(:target_user_id),
      ).to eq([newcomer.id])
    end

    it "takes moderator rights from those who stepped down, with no strike" do
      publish

      expect(stepping_down).not_to be_moderator
      expect(stepping_down.trust_level).to eq(TrustLevel[4])
      expect(stepping_down.manual_locked_trust_level).to eq(TrustLevel[4])
      expect(strikes(stepping_down)).to eq(0)
    end

    it "forgets where ballots came from once published" do
      publish
      expect(election.ballots.where.not(ip_address: nil)).to be_empty
    end

    it "doesn't touch trust levels when former moderators don't keep trust level 4" do
      SiteSetting.mod_elections_former_mods_keep_tl4 = false
      publish

      expect(newcomer).to be_moderator
      expect(newcomer.trust_level).to eq(TrustLevel[2])
      expect(stepping_down.trust_level).to eq(TrustLevel[3])
      expect(stepping_down.manual_locked_trust_level).to be_nil
    end

    it "shows the admin what will change before anything does" do
      preview = DiscourseModElections::Publisher.preview(election)

      expect(preview[:plan][:join]).to eq([newcomer])
      expect(preview[:plan][:stay]).to eq([sitting])
      expect(preview[:plan][:leave].map { |row| row[:user] }).to eq([stepping_down])
      expect(newcomer.reload).not_to be_moderator
      expect(election.reload).to be_closed
    end
  end

  describe "strikes" do
    let!(:c_sitting) { candidate(sitting, incumbent: true) }
    let!(:c_new) { candidate(newcomer) }
    let!(:c_runner_up) { candidate(runner_up) }

    before do
      ballot(voter, 3, c_new)
      ballot(Fabricate(:user), 3, c_runner_up)
      ballot(Fabricate(:user), 1, c_sitting)
    end

    it "gives a moderator who ran and lost a strike, and keeps them at trust level 4" do
      publish

      expect(sitting).not_to be_moderator
      expect(strikes(sitting)).to eq(1)
      expect(sitting.trust_level).to eq(TrustLevel[4])
      expect(sitting.manual_locked_trust_level).to eq(TrustLevel[4])
    end

    it "sends them back to trust level 3, unlocked, at the second strike" do
      DiscourseModElections::Seats.set_strikes!(sitting, 1)
      publish

      expect(strikes(sitting)).to eq(2)
      expect(sitting.trust_level).to eq(TrustLevel[3])
      expect(sitting.manual_locked_trust_level).to be_nil
    end
  end

  it "refuses to publish a contested election nobody voted in" do
    [sitting, newcomer, runner_up].each { |user| candidate(user) }

    expect { DiscourseModElections::Publisher.publish!(election, admin) }.to raise_error(
      DiscourseModElections::Error,
    ) { |e| expect(e.reason).to eq(:no_votes) }
    expect(sitting.reload).to be_moderator
  end

  it "leaves out ballots an admin set aside" do
    c_new = candidate(newcomer)
    c_runner_up = candidate(runner_up)
    election.update!(seats: 1)
    alt = ballot(Fabricate(:user), 3, c_runner_up)
    ballot(voter, 2, c_new)

    DiscourseModElections::Voting.void!(alt, "Alt account of runner_up", admin)
    publish

    expect(newcomer).to be_moderator
    expect(runner_up).not_to be_moderator
  end

  describe "seats between elections" do
    let!(:c_sitting) { candidate(sitting, incumbent: true) }
    let!(:c_new) { candidate(newcomer) }
    let!(:c_runner_up) { candidate(runner_up) }

    before do
      ballot(voter, 3, c_new, c_runner_up)
      ballot(Fabricate(:user), 3, c_sitting)
      ballot(Fabricate(:user), 2, c_runner_up)
      publish
    end

    it "sends a moderator removed for abuse back to trust level 3" do
      DiscourseModElections::Seats.vacate!(c_new.reload, "removed", admin)

      expect(newcomer.reload).not_to be_moderator
      expect(newcomer.trust_level).to eq(TrustLevel[3])
      expect(newcomer.manual_locked_trust_level).to be_nil
    end

    it "keeps a moderator who steps down at trust level 4" do
      DiscourseModElections::Seats.vacate!(c_sitting.reload, "stepped_down", admin)

      expect(sitting.reload).not_to be_moderator
      expect(sitting.manual_locked_trust_level).to eq(TrustLevel[4])
    end

    it "fills the seat by counting the same ballots without them" do
      DiscourseModElections::Seats.vacate!(c_new.reload, "stepped_down", admin)

      expect(DiscourseModElections::Countback.replacement(election).user).to eq(runner_up)
      DiscourseModElections::Countback.fill!(election, admin)

      expect(runner_up.reload).to be_moderator
      expect(c_runner_up.reload).to be_elected
      expect(election.reload.result["countbacks"].sole["candidate"]).to eq(c_runner_up.id)
      expect { DiscourseModElections::Countback.fill!(election, admin) }.to raise_error(
        DiscourseModElections::Error,
      ) { |e| expect(e.reason).to eq(:no_open_seat) }
    end

    it "skips someone who can't serve any more" do
      DiscourseModElections::Seats.vacate!(c_new.reload, "stepped_down", admin)
      runner_up.update!(suspended_till: 1.week.from_now, suspended_at: Time.zone.now)

      expect(DiscourseModElections::Countback.replacement(election)).to be_nil
    end

    context "while the next election is running" do
      let(:next_election) do
        DiscourseModElections::Election.create!(
          status: :voting,
          seats: 2,
          nominations_open_at: 2.days.ago,
          voting_open_at: 1.day.ago,
          voting_close_at: 5.days.from_now,
        )
      end
      let!(:on_next_ballot) do
        DiscourseModElections::Candidate.create!(
          election: next_election,
          user: newcomer,
          incumbent: true,
        )
      end

      it "takes a moderator removed for abuse off it, with the reason" do
        DiscourseModElections::Seats.vacate!(c_new.reload, "removed", admin)

        expect(on_next_ballot.reload).to be_disqualified
        expect(on_next_ballot.disqualified_reason).to eq(I18n.t("mod_elections.reasons.removed"))
      end

      it "drops a moderator who steps down out of it" do
        DiscourseModElections::Seats.vacate!(c_new.reload, "stepped_down", admin)

        expect(on_next_ballot.reload).to be_withdrawn
      end
    end
  end

  describe "winners who can't serve" do
    let!(:c_new) { candidate(newcomer) }
    let!(:c_runner_up) { candidate(runner_up) }

    before do
      election.update!(seats: 1)
      ballot(voter, 3, c_new)
      ballot(Fabricate(:user), 1, c_runner_up)
    end

    it "holds publishing until an admin takes them off, then the count moves on" do
      # A moderator's suspension doesn't take anyone off the ballot by itself.
      UserSuspender.new(
        newcomer,
        suspended_till: 1.week.from_now,
        reason: "campaigning",
        by_user: sitting,
      ).suspend

      preview = DiscourseModElections::Publisher.preview(election)
      expect(preview[:plan][:problems]).to eq([c_new])
      expect { DiscourseModElections::Publisher.publish!(election, admin) }.to raise_error(
        DiscourseModElections::Error,
      ) { |e| expect(e.reason).to eq(:winners_cannot_serve) }
      expect(newcomer.reload).not_to be_moderator

      DiscourseModElections::Nominations.disqualify!(c_new, "Suspended during Vote Week", admin)
      publish

      expect(runner_up).to be_moderator
      expect(newcomer).not_to be_moderator
    end

    it "takes a winner made an admin since off the ballot, and the count moves on" do
      newcomer.update!(admin: true)

      preview = DiscourseModElections::Publisher.preview(election)
      expect(c_new.reload).to be_disqualified
      expect(preview[:plan][:problems]).to be_empty
      expect(preview[:result]["elected"]).to eq([c_runner_up.id])

      publish
      expect(runner_up).to be_moderator
      expect(newcomer).not_to be_moderator
    end

    it "lets an admin take a deleted winner off the ballot" do
      UserDestroyer.new(admin).destroy(newcomer)
      expect(DiscourseModElections::Publisher.preview(election)[:plan][:problems]).to eq(
        [c_new.reload],
      )

      DiscourseModElections::Nominations.disqualify!(c_new, "Account deleted", admin)
      DiscourseModElections::Publisher.publish!(election, admin)

      expect(runner_up.reload).to be_moderator
    end
  end

  it "says which leaving moderators were never on this ballot" do
    candidate(newcomer)
    ballot(voter, 3, election.candidates.first)

    leave = DiscourseModElections::Publisher.preview(election)[:plan][:leave]
    expect(leave.map { |row| [row[:user], row[:on_ballot]] }).to contain_exactly(
      [sitting, false],
      [stepping_down, false],
    )
  end

  it "keeps a deleted account's ballot, so the count can't change after the fact" do
    c_new = candidate(newcomer)
    c_runner_up = candidate(runner_up)
    election.update!(seats: 1)
    leaving = Fabricate(:user)
    ballot(leaving, 3, c_runner_up)
    ballot(voter, 2, c_new)

    UserDestroyer.new(admin).destroy(leaving, delete_posts: true)
    expect(election.ballots.where(user_id: nil).count).to eq(1)

    publish
    expect(election.reload.result["elected"]).to eq([c_runner_up.id])
    expect(election.ballots.counted.count).to eq(2)
  end
end
