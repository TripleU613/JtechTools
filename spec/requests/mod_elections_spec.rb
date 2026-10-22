# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Mod elections endpoints" do
  fab!(:admin)
  fab!(:moderator) do
    Fabricate(
      :moderator,
      trust_level: TrustLevel[3],
      created_at: 1.year.ago,
      refresh_auto_groups: true,
    )
  end
  fab!(:member) do
    Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago, refresh_auto_groups: true)
  end
  fab!(:newbie) do
    Fabricate(:user, trust_level: TrustLevel[1], created_at: 1.year.ago, refresh_auto_groups: true)
  end
  fab!(:other) do
    Fabricate(:user, trust_level: TrustLevel[3], created_at: 1.year.ago, refresh_auto_groups: true)
  end
  fab!(:visitor) do
    Fabricate(:user, trust_level: TrustLevel[0], created_at: 1.year.ago, refresh_auto_groups: true)
  end

  before do
    SiteSetting.jtech_enabled = true
    SiteSetting.mod_elections_enabled = true
  end

  # One seat, so the sitting moderator and one more candidate are a contest:
  # with no more candidates than seats there's no Vote Week.
  def start_election(seats: 1)
    DiscourseModElections::Lifecycle.create!(
      admin,
      seats: seats,
      nominations_open_at: 1.minute.ago,
      voting_open_at: 3.days.from_now,
      voting_close_at: 6.days.from_now,
    )
  end

  def open_voting(election)
    DiscourseModElections::Lifecycle.end_phase!(election, admin)
    election.reload
  end

  it "keeps rankings out of the request log" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    expect(filter.filter("ranking" => %w[1 2])).to eq("ranking" => "[FILTERED]")
  end

  it "is not there while switched off" do
    SiteSetting.mod_elections_enabled = false
    get "/jtech-elections/current.json"
    expect(response.status).to eq(404)
  end

  describe "the page" do
    it "shows the election and its candidates to a member, and nobody's ballot" do
      election = start_election
      DiscourseModElections::Nominations.run!(member, election, "Fair and fast.")
      open_voting(election)
      DiscourseModElections::Voting.cast!(
        other,
        election,
        election.candidates.where.not(user: other).order(:id).pluck(:id),
      )

      sign_in(newbie)
      get "/jtech-elections/current.json"
      body = response.parsed_body
      expect(body.dig("election", "status")).to eq("voting")
      expect(
        body.dig("election", "candidates").map { |c| c.dig("user", "username") },
      ).to contain_exactly(moderator.username, member.username)
      expect(
        body
          .dig("election", "candidates")
          .find { |c| c.dig("user", "username") == member.username }[
          "statement"
        ],
      ).to eq("Fair and fast.")
      expect(body.dig("me", "ballot")).to be_nil
      expect(response.body).not_to include("ranking")

      sign_in(member)
      get "/jtech-elections/current.json"
      expect(response.parsed_body.dig("me", "ballot")).to be_nil
      expect(response.body).not_to include("ranking")
    end

    it "says where the step-change channel was, so the page misses nothing after it" do
      election = start_election
      DiscourseModElections::Lifecycle.end_phase!(election, admin)

      sign_in(newbie)
      get "/jtech-elections/current.json"
      expect(response.parsed_body["message_bus_last_id"]).to eq(
        MessageBus.last_id(DiscourseModElections::State::CHANNEL),
      )
      expect(response.parsed_body["message_bus_last_id"]).to be > 0
    end

    it "says when nominations stay open longer, and when there's no Vote Week" do
      election = start_election
      DiscourseModElections::Lifecycle.advance!(election, election.voting_open_at)

      sign_in(other)
      get "/jtech-elections/current.json"
      expect(response.parsed_body["election"]).to include(
        "status" => "nominating",
        "nominations_extended" => true,
        "vote_skipped" => false,
      )
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "mod_election")).to include(
        "status" => "nominating",
        "extended" => true,
      )

      DiscourseModElections::Lifecycle.advance!(election.reload, election.voting_open_at)
      get "/jtech-elections/current.json"
      expect(response.parsed_body["election"]).to include(
        "status" => "closed",
        "vote_skipped" => true,
      )

      sign_in(admin)
      get "/jtech-elections/admin/elections/#{election.id}.json"
      expect(response.parsed_body).to include(
        "vote_skipped" => true,
        "nominations_extended" => true,
      )
    end
  end

  describe "a candidate taken off the ballot" do
    it "drops off the page for everyone but admins" do
      election = start_election
      candidate = DiscourseModElections::Nominations.run!(member, election, "Vote for me")
      DiscourseModElections::Nominations.disqualify!(
        candidate,
        "Alt account of a banned user",
        admin,
      )
      row = ->(body) { body.dig("election", "candidates").find { |c| c["id"] == candidate.id } }

      [nil, other, moderator].each do |who|
        sign_in(who) if who
        get "/jtech-elections/current.json"
        expect(response.body).not_to include("Alt account")
        expect(response.body).not_to include("Vote for me")
      end

      # They still see that they were taken off.
      sign_in(member)
      get "/jtech-elections/current.json"
      expect(row.call(response.parsed_body)).to be_nil
      expect(response.parsed_body.dig("me", "candidate", "status")).to eq("disqualified")

      sign_in(admin)
      get "/jtech-elections/current.json"
      expect(row.call(response.parsed_body)["disqualified_reason"]).to eq(
        "Alt account of a banned user",
      )
    end
  end

  describe "a candidate whose account is deleted" do
    let!(:election) { start_election }

    before { DiscourseModElections::Nominations.run!(member, election, "") }

    it "comes off a ballot still open, so votes for them move on" do
      open_voting(election)
      UserDestroyer.new(admin).destroy(member)

      sign_in(other)
      get "/jtech-elections/current.json"
      expect(
        response.parsed_body.dig("election", "candidates").map { |c| c.dig("user", "username") },
      ).to eq([moderator.username])
      expect(
        DiscourseModElections::Candidate.find_by(election: election, user_id: nil),
      ).to be_withdrawn
    end

    it "stays in a closed count, for the admin to decide" do
      open_voting(election)
      DiscourseModElections::Lifecycle.end_phase!(election, admin)
      UserDestroyer.new(admin).destroy(member)

      expect(
        DiscourseModElections::Candidate.find_by(election: election, user_id: nil),
      ).to be_running
    end
  end

  describe "running" do
    let!(:election) { start_election }

    it "lets a member in good standing run, edit their statement and drop out" do
      sign_in(member)
      post "/jtech-elections/#{election.id}/candidacy.json",
           params: {
             statement: "Hi\r\n\r\n\r\n\r\nthere",
           }
      expect(response.status).to eq(200)
      expect(response.parsed_body.dig("me", "candidate", "statement")).to eq("Hi\n\nthere")

      put "/jtech-elections/#{election.id}/candidacy.json", params: { statement: "Updated" }
      expect(election.candidates.find_by(user: member).statement).to eq("Updated")

      delete "/jtech-elections/#{election.id}/candidacy.json"
      expect(election.candidates.find_by(user: member)).to be_withdrawn
    end

    it "turns away trust level 1, new accounts, recent suspensions and admins" do
      sign_in(newbie)
      post "/jtech-elections/#{election.id}/candidacy.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body.dig("extras", "reason")).to eq("trust_level")

      member.update!(created_at: 10.days.ago)
      sign_in(member)
      post "/jtech-elections/#{election.id}/candidacy.json"
      expect(response.parsed_body.dig("extras", "reason")).to eq("account_age")

      member.update!(created_at: 1.year.ago)
      # A sitting moderator's silence doesn't count: they're candidates too.
      UserHistory.create!(
        action: UserHistory.actions[:silence_user],
        target_user_id: member.id,
        acting_user_id: moderator.id,
      )
      post "/jtech-elections/#{election.id}/candidacy.json"
      expect(response.status).to eq(200)
      delete "/jtech-elections/#{election.id}/candidacy.json"

      UserHistory.create!(
        action: UserHistory.actions[:suspend_user],
        target_user_id: member.id,
        acting_user_id: admin.id,
      )
      post "/jtech-elections/#{election.id}/candidacy.json"
      expect(response.parsed_body.dig("extras", "reason")).to eq("record")

      sign_in(admin)
      post "/jtech-elections/#{election.id}/candidacy.json"
      expect(response.parsed_body.dig("extras", "reason")).to eq("admin")
    end

    it "keeps statements to the configured length" do
      SiteSetting.mod_elections_statement_max_length = 10
      sign_in(member)
      post "/jtech-elections/#{election.id}/candidacy.json", params: { statement: "x" * 11 }
      expect(response.parsed_body.dig("extras", "reason")).to eq("statement_too_long")
    end

    it "refuses API keys" do
      api_key = Fabricate(:api_key, user: member)
      post "/jtech-elections/#{election.id}/candidacy.json",
           headers: {
             "Api-Key" => api_key.key,
             "Api-Username" => member.username,
           }
      expect(response.status).to eq(403)
      expect(election.candidates.find_by(user: member)).to be_nil
    end
  end

  describe "voting" do
    let!(:election) { start_election }
    let(:mod_candidate) { election.candidates.find_by(user: moderator) }
    let!(:member_candidate) { DiscourseModElections::Nominations.run!(member, election, "") }

    before { open_voting(election) }

    it "saves a ranking at the voter's weight, and lets them change and take it back" do
      sign_in(other)
      put "/jtech-elections/#{election.id}/ballot.json",
          params: {
            ranking: [member_candidate.id, mod_candidate.id],
          }
      expect(response.status).to eq(200)
      ballot = DiscourseModElections::Ballot.find_by(election: election, user: other)
      expect(ballot.ranking).to eq([member_candidate.id, mod_candidate.id])
      expect(ballot.weight).to eq(3)
      expect(response.parsed_body.dig("me", "ballot", "ranking")).to eq(ballot.ranking)

      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [mod_candidate.id] }
      expect(ballot.reload.ranking).to eq([mod_candidate.id])

      delete "/jtech-elections/#{election.id}/ballot.json"
      expect(DiscourseModElections::Ballot.exists?(ballot.id)).to eq(false)
    end

    it "doesn't let candidates vote for themselves" do
      sign_in(member)
      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [member_candidate.id] }
      expect(response.parsed_body.dig("extras", "reason")).to eq("self_vote")

      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [mod_candidate.id] }
      expect(response.status).to eq(200)
    end

    it "turns away people who weren't on the voter list, admins, and junk ballots" do
      late = Fabricate(:user, trust_level: TrustLevel[2])
      sign_in(late)
      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [mod_candidate.id] }
      expect(response.parsed_body.dig("extras", "reason")).to eq("not_on_roll")

      sign_in(admin)
      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [mod_candidate.id] }
      expect(response.parsed_body.dig("extras", "reason")).to eq("admin")

      sign_in(other)
      put "/jtech-elections/#{election.id}/ballot.json",
          params: {
            ranking: [mod_candidate.id, mod_candidate.id],
          }
      expect(response.parsed_body.dig("extras", "reason")).to eq("invalid_ballot")

      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [-5] }
      expect(response.parsed_body.dig("extras", "reason")).to eq("invalid_ballot")

      put "/jtech-elections/#{election.id}/ballot.json",
          params: {
            ranking: {
              first: mod_candidate.id,
            },
          }
      expect(response.status).to eq(422)
      expect(response.parsed_body.dig("extras", "reason")).to eq("empty_ballot")
    end

    it "turns away voters suspended since the list was made" do
      other.update!(suspended_till: 1.week.from_now, suspended_at: Time.zone.now)
      sign_in(other)
      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [mod_candidate.id] }
      expect(response.status).to eq(403).or eq(422)
      expect(DiscourseModElections::Ballot.where(user: other)).to be_empty
    end
  end

  describe "someone who stops qualifying during the election" do
    fab!(:voter) do
      Fabricate(
        :user,
        trust_level: TrustLevel[2],
        created_at: 1.year.ago,
        refresh_auto_groups: true,
      )
    end
    let!(:election) { start_election }
    let(:mod_candidate) { election.candidates.find_by(user: moderator) }
    let!(:member_candidate) { DiscourseModElections::Nominations.run!(member, election, "") }
    let!(:other_candidate) { DiscourseModElections::Nominations.run!(other, election, "") }

    before { open_voting(election) }

    def suspend(user, by)
      UserSuspender.new(user, suspended_till: 1.year.from_now, reason: "spam", by_user: by).suspend
    end

    it "takes a candidate an admin bans or anonymizes off the ballot in Vote Week" do
      suspend(member, admin)
      expect(member_candidate.reload).to be_disqualified
      expect(member_candidate.disqualified_reason).to eq(I18n.t("mod_elections.reasons.ineligible"))
      expect(member_candidate.disqualified_by_id).to eq(Discourse::SYSTEM_USER_ID)
      expect(
        UserHistory.where(
          custom_type: "mod_election_disqualify",
          target_user_id: member.id,
          acting_user_id: Discourse::SYSTEM_USER_ID,
        ),
      ).to exist
      note = Notification.where(user: member, notification_type: Notification.types[:custom]).last
      expect(JSON.parse(note.data)).to include("mod_election_kind" => "ineligible")

      UserAnonymizer.make_anonymous(other, admin)
      expect(other_candidate.reload).to be_disqualified

      sign_in(voter)
      get "/jtech-elections/current.json"
      expect(response.parsed_body.dig("election", "candidates").map { |c| c["id"] }).to eq(
        [mod_candidate.id],
      )
      expect(response.body).not_to include(other.reload.username)
      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [member_candidate.id] }
      expect(response.parsed_body.dig("extras", "reason")).to eq("invalid_ballot")
      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [mod_candidate.id] }
      expect(response.status).to eq(200)
    end

    it "takes off a candidate whose trust level drops below the minimum, but not a sitting moderator" do
      member.change_trust_level!(TrustLevel[1])
      expect(member_candidate.reload).to be_disqualified

      # Sitting moderators can always run.
      moderator.change_trust_level!(TrustLevel[1])
      expect(mod_candidate.reload).to be_running
      suspend(moderator, admin)
      expect(mod_candidate.reload).to be_disqualified
    end

    it "leaves a candidate a moderator suspends or silences on the ballot" do
      suspend(member, moderator)
      UserSilencer.new(other, moderator, reason: "campaigning").silence

      expect(member_candidate.reload).to be_running
      expect(other_candidate.reload).to be_running
      DiscourseModElections::Lifecycle.tick
      expect(member_candidate.reload).to be_running
    end

    it "catches at the next tick what no event announces" do
      member.update!(active: false)
      other.update!(admin: true)
      expect(member_candidate.reload).to be_running

      DiscourseModElections::Lifecycle.tick
      expect(member_candidate.reload).to be_disqualified
      expect(other_candidate.reload).to be_disqualified
      expect(mod_candidate.reload).to be_running
    end

    it "takes them off after voting closes too, so the count moves on" do
      DiscourseModElections::Voting.cast!(voter, election, [member_candidate.id, mod_candidate.id])
      DiscourseModElections::Lifecycle.end_phase!(election, admin)
      expect(election.reload).to be_closed

      member.change_trust_level!(TrustLevel[1])
      expect(member_candidate.reload).to be_disqualified
      preview = DiscourseModElections::Publisher.preview(election)
      expect(preview[:result]["elected"]).to eq([mod_candidate.id])
    end

    it "refuses to put back someone who'd only come off again" do
      member.change_trust_level!(TrustLevel[1])
      sign_in(admin)

      post "/jtech-elections/admin/elections/#{election.id}/candidates/#{member_candidate.id}/reinstate.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body.dig("extras", "reason")).to eq("cannot_run")
      expect(member_candidate.reload).to be_disqualified

      member.change_trust_level!(TrustLevel[2])
      post "/jtech-elections/admin/elections/#{election.id}/candidates/#{member_candidate.id}/reinstate.json"
      expect(response.status).to eq(200)
      expect(member_candidate.reload).to be_running
    end

    it "takes away the vote, and sets the ballot aside if they still can't vote when Vote Week ends" do
      DiscourseModElections::Voting.cast!(newbie, election, [member_candidate.id])
      DiscourseModElections::Voting.cast!(voter, election, [mod_candidate.id])
      newbie.change_trust_level!(TrustLevel[0])
      suspend(voter, admin)

      expect(DiscourseModElections::Notifier.voter_ids(election, "reminder")).not_to include(
        newbie.id,
        voter.id,
      )
      sign_in(newbie)
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "can_view_mod_elections")).to eq(false)
      expect(response.parsed_body.dig("current_user", "mod_election", "voter")).to eq(false)
      put "/jtech-elections/#{election.id}/ballot.json", params: { ranking: [mod_candidate.id] }
      expect(response.status).to eq(422)
      expect(response.parsed_body.dig("extras", "reason")).to eq("not_allowed")
      expect(DiscourseModElections::Ballot.find_by(user: newbie).ranking).to eq(
        [member_candidate.id],
      )

      # Back in good standing before the close: their ballot stands.
      voter.update!(suspended_till: nil, suspended_at: nil)
      DiscourseModElections::Lifecycle.end_phase!(election, admin)

      set_aside = DiscourseModElections::Ballot.find_by(user: newbie)
      expect(set_aside).to be_voided
      expect(set_aside.void_reason).to eq(I18n.t("mod_elections.reasons.cannot_vote"))
      expect(DiscourseModElections::Ballot.find_by(user: voter)).not_to be_voided
      expect(DiscourseModElections::Presenter.me_json(election.reload, newbie)[:receipt]).to eq(
        counted: false,
        reason: I18n.t("mod_elections.reasons.cannot_vote"),
      )

      # The admin can put it back until the first preview.
      DiscourseModElections::Voting.restore!(set_aside, admin)
      expect(set_aside.reload).not_to be_voided
    end

    it "leaves anonymized accounts off the next voter list" do
      DiscourseModElections::Publisher.cancel!(election, admin)
      UserAnonymizer.make_anonymous(newbie, admin)

      expect(start_election.voters.pluck(:user_id)).not_to include(newbie.id)
    end
  end

  describe "the admin tab" do
    let!(:election) { start_election(seats: 1) }

    it "is for admins only: moderators are candidates" do
      sign_in(moderator)
      get "/jtech-elections/admin.json"
      expect(response.status).to eq(404)
      get "/jtech-elections/admin/elections/#{election.id}.json"
      expect(response.status).to eq(404)
      get "/jtech-elections/admin/elections/#{election.id}/ip-report.json"
      expect(response.status).to eq(404)

      sign_in(admin)
      get "/jtech-elections/admin.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["elections"].map { |e| e["id"] }).to eq([election.id])
    end

    it "finds ballots cast from one address, lets the admin set them aside, and publishes" do
      member_candidate = DiscourseModElections::Nominations.run!(member, election, "")
      mod_candidate = election.candidates.find_by(user: moderator)
      open_voting(election)

      alt = Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago)
      DiscourseModElections::Voter.create!(election: election, user: alt, weight: 2)
      sign_in(other)
      put "/jtech-elections/#{election.id}/ballot.json",
          params: {
            ranking: [mod_candidate.id],
          },
          env: {
            "REMOTE_ADDR" => "203.0.113.9",
          }
      sign_in(alt)
      put "/jtech-elections/#{election.id}/ballot.json",
          params: {
            ranking: [member_candidate.id],
          },
          env: {
            "REMOTE_ADDR" => "198.51.100.7",
          }
      sign_in(newbie)
      put "/jtech-elections/#{election.id}/ballot.json",
          params: {
            ranking: [member_candidate.id],
          },
          env: {
            "REMOTE_ADDR" => "198.51.100.7",
          }

      sign_in(admin)
      # During Vote Week it would say who has voted.
      get "/jtech-elections/admin/elections/#{election.id}/ip-report.json"
      expect(response.parsed_body.dig("extras", "reason")).to eq("not_closed")
      void_url = ->(id) do
        "/jtech-elections/admin/elections/#{election.id}/ballots/#{id}/void.json"
      end
      post void_url.call(DiscourseModElections::Ballot.find_by(user: alt).id),
           params: {
             reason: "Too early",
           }
      expect(response.parsed_body.dig("extras", "reason")).to eq("not_closed")

      post "/jtech-elections/admin/elections/#{election.id}/end-phase.json"
      expect(response.parsed_body["status"]).to eq("closed")

      get "/jtech-elections/admin/elections/#{election.id}/ip-report.json"
      group = response.parsed_body["ip_report"].sole
      expect(group["ip"]).to eq("198.51.100.7")
      expect(group["ballots"].map { |b| b.dig("user", "username") }).to contain_exactly(
        alt.username,
        newbie.username,
      )
      expect(response.body).not_to include("ranking")

      group["ballots"].each do |b|
        post "/jtech-elections/admin/elections/#{election.id}/ballots/#{b["id"]}/void.json",
             params: {
               reason: "Same household, alt accounts",
             }
        expect(response.status).to eq(200)
      end

      post "/jtech-elections/admin/elections/#{election.id}/preview.json"
      expect(response.parsed_body.dig("result", "elected")).to eq([mod_candidate.id])
      expect(response.parsed_body.dig("plan", "stay").map { |u| u["id"] }).to eq([moderator.id])
      expect(response.parsed_body.dig("result", "candidates").map { |c| c["username"] }).to include(
        moderator.username,
      )

      # The ballots are fixed now: a ballot set aside between two previews
      # would show, in the difference, what was on it.
      restore_url = "/jtech-elections/admin/elections/#{election.id}/ballots/"
      post "#{restore_url}#{group["ballots"].first["id"]}/restore.json"
      expect(response.parsed_body.dig("extras", "reason")).to eq("count_previewed")
      post void_url.call(DiscourseModElections::Ballot.find_by(user: other).id),
           params: {
             reason: "Late doubts",
           }
      expect(response.parsed_body.dig("extras", "reason")).to eq("count_previewed")
      get "/jtech-elections/admin/elections/#{election.id}.json"
      expect(response.parsed_body["previewed_at"]).to be_present

      ids_before = DiscourseModElections::Ballot.where(election: election).pluck(:id)
      post "/jtech-elections/admin/elections/#{election.id}/publish.json"
      expect(response.status).to eq(200)
      expect(moderator.reload).to be_moderator
      expect(member.reload).not_to be_moderator

      get "/jtech-elections/current.json", params: { id: election.id }
      expect(response.parsed_body.dig("election", "result", "elected")).to eq([mod_candidate.id])
      expect(response.parsed_body.dig("election", "turnout", "ballots")).to eq(1)

      # No ballot says whose it was any more, or where it came from; the
      # set-aside ones keep no ranking.
      ballots = DiscourseModElections::Ballot.where(election: election)
      expect(ballots.pluck(:user_id, :ip_address, :voided_by_id).flatten.compact).to be_empty
      expect(ballots.where.not(voided_at: nil).pluck(:ranking)).to eq([[], []])
      expect(ballots.counted.pluck(:ranking)).to eq([[mod_candidate.id]])
      # Nor under the ids the address report showed beside each voter.
      expect(ballots.count).to eq(3)
      expect(ballots.where(id: ids_before)).to be_empty

      # Each voter still sees what became of theirs.
      sign_in(other)
      get "/jtech-elections/current.json", params: { id: election.id }
      expect(response.parsed_body["me"]).to include(
        "ballot" => nil,
        "receipt" => {
          "counted" => true,
          "reason" => nil,
        },
      )
      sign_in(alt)
      get "/jtech-elections/current.json", params: { id: election.id }
      expect(response.parsed_body.dig("me", "receipt")).to eq(
        "counted" => false,
        "reason" => "Same household, alt accounts",
      )
    end

    it "deletes the ballots of a cancelled election" do
      DiscourseModElections::Nominations.run!(member, election, "")
      open_voting(election)
      DiscourseModElections::Voting.cast!(other, election, [election.candidates.first.id])

      DiscourseModElections::Publisher.cancel!(election, admin)

      expect(DiscourseModElections::Ballot.where(election: election)).to be_empty
    end

    it "lists suspensions and silences a moderator gave candidates or voters" do
      DiscourseModElections::Nominations.run!(member, election, "")
      UserSilencer.new(member, moderator, reason: "campaigning").silence
      UserSilencer.new(newbie, admin, reason: "spam").silence

      sign_in(admin)
      get "/jtech-elections/admin/elections/#{election.id}.json"

      expect(response.parsed_body["moderator_actions"]).to contain_exactly(
        include(
          "action" => "silence",
          "by" => include("username" => moderator.username),
          "user" => include("username" => member.username),
        ),
      )
    end

    it "lets an admin take a candidate off the ballot with a public reason" do
      member_candidate = DiscourseModElections::Nominations.run!(member, election, "")
      sign_in(admin)

      post "/jtech-elections/admin/elections/#{election.id}/candidates/#{member_candidate.id}/disqualify.json"
      expect(response.parsed_body.dig("extras", "reason")).to eq("reason_required")

      post "/jtech-elections/admin/elections/#{election.id}/candidates/#{member_candidate.id}/disqualify.json",
           params: {
             reason: "Vote buying",
           }
      expect(member_candidate.reload).to be_disqualified

      get "/jtech-elections/current.json"
      shown =
        response
          .parsed_body
          .dig("election", "candidates")
          .find { |c| c["id"] == member_candidate.id }
      expect(shown).to include("status" => "disqualified", "disqualified_reason" => "Vote buying")

      post "/jtech-elections/admin/elections/#{election.id}/candidates/#{member_candidate.id}/reinstate.json"
      expect(response.status).to eq(200)
      expect(member_candidate.reload).to be_running
    end

    it "refuses every change to moderators and anonymous visitors" do
      member_candidate = DiscourseModElections::Nominations.run!(member, election, "")
      writes = [
        "/jtech-elections/admin/elections.json",
        "/jtech-elections/admin/elections/#{election.id}/end-phase.json",
        "/jtech-elections/admin/elections/#{election.id}/cancel.json",
        "/jtech-elections/admin/elections/#{election.id}/candidates/#{member_candidate.id}/disqualify.json",
        "/jtech-elections/admin/elections/#{election.id}/candidates/#{member_candidate.id}/reinstate.json",
        "/jtech-elections/admin/elections/#{election.id}/publish.json",
        "/jtech-elections/admin/seats/fill.json",
      ]

      [nil, moderator].each do |who|
        sign_in(who) if who
        writes.each do |path|
          post path, params: { reason: "x" }
          expect(response.status).to be_in([403, 404]), "#{who&.username || "anon"} → #{path}"
        end
      end
      expect(election.reload).to be_nominating
      expect(member_candidate.reload).to be_running
    end

    it "changes an election's seats and dates for admins only, and says what can change" do
      closes = 10.days.from_now.change(usec: 0)
      [nil, moderator].each do |who|
        sign_in(who) if who
        put "/jtech-elections/admin/elections/#{election.id}.json", params: { seats: 4 }
        expect(response.status).to be_in([403, 404]), "#{who&.username || "anon"} changed it"
      end
      expect(election.reload.seats).to eq(1)

      sign_in(admin)
      get "/jtech-elections/admin/elections/#{election.id}.json"
      expect(response.parsed_body["editable"]).to eq(%w[seats voting_open_at voting_close_at])

      put "/jtech-elections/admin/elections/#{election.id}.json",
          params: {
            seats: 4,
            voting_close_at: closes.iso8601,
          }
      expect(response.status).to eq(200)
      expect(response.parsed_body).to include("seats" => 4)
      expect(election.reload.voting_close_at).to eq_time(closes)

      put "/jtech-elections/admin/elections/#{election.id}.json",
          params: {
            voting_open_at: 30.seconds.ago.iso8601,
          }
      expect(response.status).to eq(422)
      expect(response.parsed_body.dig("extras", "reason")).to eq("edit_in_past")
    end

    it "ends a phase early and cancels" do
      DiscourseModElections::Nominations.run!(member, election, "")
      sign_in(admin)
      post "/jtech-elections/admin/elections/#{election.id}/end-phase.json"
      expect(response.parsed_body["status"]).to eq("voting")

      post "/jtech-elections/admin/elections/#{election.id}/cancel.json"
      expect(response.parsed_body["status"]).to eq("cancelled")
      expect(moderator.reload).to be_moderator
    end

    it "shows what happened but changes nothing while the module is off" do
      sign_in(admin)
      SiteSetting.mod_elections_enabled = false

      get "/jtech-elections/admin.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["enabled"]).to eq(false)
      get "/jtech-elections/admin/elections/#{election.id}.json"
      expect(response.status).to eq(200)

      post "/jtech-elections/admin/elections/#{election.id}/cancel.json"
      expect(response.status).to eq(422)
      expect(response.parsed_body.dig("extras", "reason")).to eq("module_off")
      expect(election.reload).to be_nominating
    end
  end

  describe "seats between elections" do
    fab!(:runner_up) { Fabricate(:user, trust_level: TrustLevel[2], created_at: 1.year.ago) }

    let!(:election) { start_election(seats: 1) }

    before do
      DiscourseModElections::Nominations.run!(member, election, "")
      DiscourseModElections::Nominations.run!(runner_up, election, "")
      open_voting(election)
      candidates = election.candidates.index_by(&:user_id)
      DiscourseModElections::Voting.cast!(
        other,
        election,
        [candidates[member.id].id, candidates[runner_up.id].id],
      )
      DiscourseModElections::Voting.cast!(newbie, election, [candidates[runner_up.id].id])
      DiscourseModElections::Lifecycle.end_phase!(election, admin)
      DiscourseModElections::Publisher.publish!(election, admin)
    end

    it "lets an admin record who left, then fills the seat by countback" do
      seat = election.candidates.find_by(user: member)
      sign_in(admin)

      get "/jtech-elections/admin/seats.json"
      expect(response.parsed_body["holders"].map { |h| h["id"] }).to eq([seat.id])

      post "/jtech-elections/admin/seats/#{seat.id}/vacate.json", params: { reason: "removed" }
      expect(response.parsed_body["open"]).to eq(1)
      expect(member.reload).not_to be_moderator
      # Seated at a locked TL4; removed for abuse, straight back to TL3.
      expect(member.trust_level).to eq(TrustLevel[3])
      expect(member.manual_locked_trust_level).to be_nil

      get "/jtech-elections/admin/seats/countback.json"
      expect(response.parsed_body.dig("replacement", "username")).to eq(runner_up.username)

      post "/jtech-elections/admin/seats/fill.json"
      expect(response.parsed_body["open"]).to eq(0)
      expect(runner_up.reload).to be_moderator

      post "/jtech-elections/admin/seats/fill.json"
      expect(response.parsed_body.dig("extras", "reason")).to eq("no_open_seat")
    end

    it "tells open elections pages when a seat is left or filled" do
      seat = election.candidates.find_by(user: member)
      messages =
        MessageBus.track_publish(DiscourseModElections::State::CHANNEL) do
          DiscourseModElections::Seats.vacate!(seat, "stepped_down", admin)
          DiscourseModElections::Countback.fill!(election, admin)
        end
      expect(messages.size).to eq(2)
    end

    it "shows a voter, after the results, that their ballot was counted" do
      sign_in(other)
      get "/jtech-elections/current.json", params: { id: election.id }

      expect(response.parsed_body.dig("me", "receipt")).to eq("counted" => true, "reason" => nil)
      expect(response.parsed_body.dig("election", "turnout", "ballots")).to eq(2)
    end

    it "gives dates as days on the forum's calendar, wherever the reader is" do
      # Already February 1 in Auckland, still January 31 in UTC.
      SiteSetting.mod_elections_timezone = "Pacific/Auckland"
      election.update!(nominations_open_at: Time.zone.parse("2026-01-31 12:00 UTC"))

      sign_in(other)
      get "/jtech-elections/current.json", params: { id: election.id }
      body = response.parsed_body

      expect(body["history"].map { |row| row["label"] }).to eq(["February 2026"])
      expect(body.dig("election", "days", "nominations")).to eq("February 1")
      opens = DiscourseModElections::Schedule.next_opening.in_time_zone("Pacific/Auckland")
      expect(body["next_opening"]).to eq(I18n.l(opens.to_date, format: "%B %-d, %Y"))
    end

    it "shows the winners as their accounts are now, real names only where the forum shows them" do
      member.update!(name: "Real Name")
      UsernameChanger.change(member, "renamed_member", admin)
      SiteSetting.enable_names = false

      sign_in(other)
      get "/jtech-elections/current.json", params: { id: election.id }
      winner =
        response
          .parsed_body
          .dig("election", "result", "candidates")
          .find { |c| c["user_id"] == member.id }
      expect(winner["username"]).to eq("renamed_member")
      expect(winner["name"]).to be_nil
      expect(election.reload.result.to_json).not_to include("renamed_member")
    end

    it "leaves an admin's trust level alone when their old seat is recorded as left" do
      seat = election.candidates.find_by(user: member)
      member.update!(admin: true)
      level = member.reload.trust_level

      sign_in(admin)
      post "/jtech-elections/admin/seats/#{seat.id}/vacate.json", params: { reason: "removed" }

      expect(response.parsed_body["open"]).to eq(1)
      expect(member.reload.trust_level).to eq(level)
      expect(
        UserHistory.where(custom_type: "mod_election_vacate", target_user_id: member.id),
      ).to exist
    end

    it "takes someone off a later ballot when they're removed from their seat" do
      later = start_election
      # A sitting moderator, so on the new ballot from the start.
      expect(later.candidates.find_by(user: member)).to be_running

      sign_in(admin)
      seat = election.candidates.find_by(user: member)
      post "/jtech-elections/admin/seats/#{seat.id}/vacate.json", params: { reason: "removed" }

      expect(later.candidates.find_by(user: member)).to be_disqualified
    end
  end

  describe "the signed-in user's summary" do
    let!(:election) { start_election }

    it "carries the step and, in Vote Week, whether they still have a vote to cast" do
      sign_in(other)
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "mod_election")).to include(
        "id" => election.id,
        "status" => "nominating",
      )

      DiscourseModElections::Nominations.run!(member, election, "")
      open_voting(election)
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "mod_election")).to include(
        "status" => "voting",
        "voter" => true,
        "voted" => false,
      )

      DiscourseModElections::Voting.cast!(other, election, [election.candidates.first.id])
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "mod_election", "voted")).to eq(true)
    end

    it "isn't there with no election running, or with the module off" do
      sign_in(other)
      SiteSetting.mod_elections_enabled = false
      get "/session/current.json"
      expect(response.parsed_body["current_user"]).not_to have_key("mod_election")

      SiteSetting.mod_elections_enabled = true
      DiscourseModElections::Publisher.cancel!(election, admin)
      get "/session/current.json"
      expect(response.parsed_body["current_user"]).not_to have_key("mod_election")
    end
  end

  describe "rate limits" do
    let!(:election) { start_election }

    it "stops a script hammering the ballot or candidacy" do
      RateLimiter.enable
      sign_in(member)
      statuses =
        Array.new(32) do
          put "/jtech-elections/#{election.id}/candidacy.json", params: { statement: "x" }
          response.status
        end
      expect(statuses.last).to eq(429)
    end
  end

  describe "who can see the page" do
    before { start_election }

    it "turns a visitor away" do
      get "/jtech-elections/current.json"
      expect(response.status).to eq(403)
    end

    it "is for trust level 1 and up by default" do
      sign_in(visitor)
      get "/jtech-elections/current.json"
      expect(response.status).to eq(403)

      sign_in(newbie)
      get "/jtech-elections/current.json"
      expect(response.status).to eq(200)
    end

    it "follows mod_elections_view_allowed_groups, staff aside" do
      SiteSetting.mod_elections_view_allowed_groups = Group::AUTO_GROUPS[:trust_level_3].to_s
      # On the voter list from when nominations opened: that's no way in.
      sign_in(newbie)
      get "/jtech-elections/current.json"
      expect(response.status).to eq(403)

      sign_in(other)
      get "/jtech-elections/current.json"
      expect(response.status).to eq(200)

      SiteSetting.mod_elections_view_allowed_groups = ""
      sign_in(moderator)
      get "/jtech-elections/current.json"
      expect(response.status).to eq(200)
    end

    it "only lists voters and takes candidates who could open the page" do
      DiscourseModElections::Publisher.cancel!(DiscourseModElections::Election.last, admin)
      SiteSetting.mod_elections_view_allowed_groups = Group::AUTO_GROUPS[:trust_level_3].to_s
      election = start_election
      expect(election.voters.pluck(:user_id)).to contain_exactly(moderator.id, other.id)
      expect(DiscourseModElections::Eligibility.could_run(election)).not_to include(member)
      expect(DiscourseModElections::Eligibility.run_blocked_reason(member, election)).to eq(
        :not_allowed,
      )
      expect(DiscourseModElections::Eligibility.run_blocked_reason(other, election)).to be_nil

      sign_in(member)
      get "/jtech-elections/current.json"
      expect(response.status).to eq(403)
    end

    it "tells the browser who may open it" do
      sign_in(visitor)
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "can_view_mod_elections")).to eq(false)

      sign_in(newbie)
      get "/session/current.json"
      expect(response.parsed_body.dig("current_user", "can_view_mod_elections")).to eq(true)
    end
  end
end
