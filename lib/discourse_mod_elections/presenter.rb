# frozen_string_literal: true

module DiscourseModElections
  # JSON for the elections page, Dumbcourse and the admin tab.
  module Presenter
    # The election the page opens on: the one in progress, else the latest
    # published one.
    def self.default_election
      Election.where(status: %i[nominating voting closed]).order(:id).last ||
        Election.published.order(published_at: :desc).first
    end

    def self.page(election, user, guardian)
      {
        election: election && election_json(election, user, guardian),
        me: election && user && me_json(election, user),
        limits: limits,
        history: history,
        # The calendar's zone, so dates show as the forum's calendar days
        # wherever the reader is.
        timezone: Schedule.zone.tzinfo.name,
        next_opening: DiscourseModElections.enabled? ? Schedule.next_opening : nil,
      }
    end

    def self.history
      Election
        .where(status: %i[published cancelled])
        .order(nominations_open_at: :desc)
        .limit(20)
        .map do |election|
          {
            id: election.id,
            status: election.status,
            label: month_label(election),
            nominations_open_at: election.nominations_open_at,
            published_at: election.published_at,
          }
        end
    end

    # "January 2027", from the calendar's zone: a reader in Los Angeles
    # still sees January for an election that opened at midnight in New
    # York on the 1st.
    def self.month_label(election)
      I18n.l(election.nominations_open_at.in_time_zone(Schedule.zone).to_date, format: "%B %Y")
    end

    def self.limits
      {
        candidate_min_trust_level: SiteSetting.mod_elections_candidate_min_trust_level.to_i,
        candidate_min_account_age_days: SiteSetting.mod_elections_candidate_min_account_age_days,
        candidate_clean_record_days: SiteSetting.mod_elections_candidate_clean_record_days,
        voter_min_account_age_days: SiteSetting.mod_elections_voter_min_account_age_days,
        statement_max_length: SiteSetting.mod_elections_statement_max_length,
      }
    end

    def self.election_json(election, user, guardian)
      candidates = election.candidates.where.not(status: :withdrawn).includes(:user).to_a
      {
        id: election.id,
        status: election.status,
        seats: election.seats,
        nominations_open_at: election.nominations_open_at,
        voting_open_at: election.voting_open_at,
        voting_close_at: election.voting_close_at,
        topic_url: topic_url(election, guardian),
        candidates: order(candidates, election, user).map { |c| candidate_json(c) },
        result: election.published? ? election.result : nil,
        turnout: election.published? ? turnout(election) : nil,
      }
    end

    def self.topic_url(election, guardian)
      topic = election.topic
      topic.relative_url if topic && guardian.can_see?(topic)
    end

    # A shuffled order for each voter during Vote Week, the same one every
    # time they look, so the top of the list isn't always the same name.
    # Alphabetical otherwise.
    def self.order(candidates, election, user)
      if election.voting? && user
        candidates.sort_by { |c| Digest::SHA256.hexdigest("#{election.id}:#{user.id}:#{c.id}") }
      else
        candidates.sort_by { |c| c.user&.username_lower.to_s }
      end
    end

    def self.candidate_json(candidate)
      {
        id: candidate.id,
        user: basic_user(candidate.user),
        statement: candidate.statement,
        incumbent: candidate.incumbent,
        status: candidate.status,
        disqualified_reason: candidate.disqualified_reason,
        elected: candidate.elected,
        seat_left_reason: candidate.seat_left_reason,
      }
    end

    def self.me_json(election, user)
      candidate = election.candidates.find_by(user_id: user.id)
      weight = Roll.weight_for(election, user)
      ballot = Ballot.find_by(election_id: election.id, user_id: user.id)
      {
        candidate:
          candidate &&
            {
              id: candidate.id,
              status: candidate.status,
              statement: candidate.statement,
              incumbent: candidate.incumbent,
            },
        run_blocked: election.nominating? ? Eligibility.run_blocked_reason(user, election) : nil,
        weight: weight,
        vote_blocked:
          election.voting? ? Eligibility.vote_blocked_reason(user, election, weight) : nil,
        ballot:
          ballot &&
            {
              ranking: ballot.ranking,
              voided: ballot.voided?,
              void_reason: ballot.void_reason,
              updated_at: ballot.updated_at,
            },
      }
    end

    def self.turnout(election)
      {
        voters: election.voters.count,
        ballots: election.ballots.counted.count,
        weight: election.ballots.counted.sum(:weight),
      }
    end

    # What the banner and sidebar need on every page: counts and flags only.
    def self.current_user_summary(user)
      active = State.active
      return if active.nil?
      summary = active.dup
      if active[:status] == "voting"
        weight = Voter.where(election_id: active[:id], user_id: user.id).pick(:weight)
        summary[:voter] = weight.present? && !user.admin?
        summary[:voted] = weight.present? &&
          Ballot.where(election_id: active[:id], user_id: user.id).exists?
      end
      summary
    end

    def self.basic_user(user)
      return if user.nil?
      {
        id: user.id,
        username: user.username,
        name: user.name,
        avatar_template: user.avatar_template,
      }
    end

    # ── Admin ────────────────────────────────────────────────────────────

    def self.admin_index
      seated_election = Countback.current_election
      {
        enabled: DiscourseModElections.enabled?,
        schedule: {
          months: Schedule.months,
          timezone: Schedule.zone.tzinfo.name,
          next_opening: Schedule.next_opening,
          seats: SiteSetting.mod_elections_seats,
          nomination_days: SiteSetting.mod_elections_nomination_days,
          voting_days: SiteSetting.mod_elections_voting_days,
        },
        elections:
          Election
            .order(nominations_open_at: :desc)
            .limit(20)
            .map do |election|
              {
                id: election.id,
                status: election.status,
                seats: election.seats,
                nominations_open_at: election.nominations_open_at,
                voting_open_at: election.voting_open_at,
                voting_close_at: election.voting_close_at,
                published_at: election.published_at,
              }
            end,
        seats: seated_election && seats_json(seated_election),
        sitting: Seats.sitting.order(:username).map { |user| basic_user(user) },
      }
    end

    def self.seats_json(election)
      candidates = election.candidates.where(elected: true).includes(:user).order(:id)
      open_seats = election.seats - candidates.count { |c| c.seat_left_at.nil? }
      {
        election_id: election.id,
        seats: election.seats,
        open: [open_seats, 0].max,
        holders:
          candidates.map do |c|
            {
              id: c.id,
              user: basic_user(c.user),
              seat_left_at: c.seat_left_at,
              seat_left_reason: c.seat_left_reason,
            }
          end,
      }
    end

    def self.admin_election(election)
      ballots = election.ballots
      {
        id: election.id,
        status: election.status,
        seats: election.seats,
        nominations_open_at: election.nominations_open_at,
        voting_open_at: election.voting_open_at,
        voting_close_at: election.voting_close_at,
        topic_id: election.topic_id,
        created_by: basic_user(election.created_by),
        published_at: election.published_at,
        published_by: basic_user(election.published_by),
        candidates:
          election
            .candidates
            .includes(:user)
            .sort_by { |c| c.user&.username_lower.to_s }
            .map do |c|
              candidate_json(c).merge(
                trust_level: c.user&.trust_level,
                seat_left_at: c.seat_left_at,
              )
            end,
        turnout: {
          voters: election.voters.count,
          voters_weight: election.voters.sum(:weight),
          ballots: ballots.counted.count,
          ballots_weight: ballots.counted.sum(:weight),
          voided: ballots.where.not(voided_at: nil).count,
        },
        result: election.result,
      }
    end

    def self.ip_report(election)
      IpReport
        .for(election)
        .map do |row|
          {
            ip: row[:ip],
            ballots:
              row[:ballots].map do |ballot|
                {
                  id: ballot.id,
                  user: basic_user(ballot.user),
                  trust_level: ballot.user&.trust_level,
                  weight: ballot.weight,
                  account_created_at: ballot.user&.created_at,
                  voided: ballot.voided?,
                  void_reason: ballot.void_reason,
                }
              end,
            candidates: row[:candidates].map { |user| basic_user(user) },
          }
        end
    end

    def self.plan(plan)
      {
        join: plan[:join].map { |user| basic_user(user) },
        stay: plan[:stay].map { |user| basic_user(user) },
        leave:
          plan[:leave].map do |row|
            basic_user(row[:user]).merge(
              strike: row[:strike],
              strikes: row[:strikes],
              trust_level: row[:trust_level],
              on_ballot: row[:on_ballot],
            )
          end,
        problems:
          plan[:problems].map do |candidate|
            {
              candidate_id: candidate.id,
              user: basic_user(candidate.user),
              reason: problem_reason(candidate.user),
            }
          end,
      }
    end

    # Why a winner can't take their seat, for the admin's preview.
    def self.problem_reason(user)
      return "deleted" if user.nil?
      return "admin" if user.admin?
      return "suspended" if user.suspended?
      return "silenced" if user.silenced?
      "inactive"
    end
  end
end
