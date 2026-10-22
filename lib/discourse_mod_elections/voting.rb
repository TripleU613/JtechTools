# frozen_string_literal: true

module DiscourseModElections
  # Casting, changing and taking back a ballot during Vote Week.
  module Voting
    # Under the election's lock, which closing the vote takes too: a ballot
    # either lands before the close or is turned away, never after.
    def self.cast!(user, election, ranking, ip_address: nil)
      ids = parse(ranking)
      election.with_lock do
        voter = Voter.find_by(election_id: election.id, user_id: user.id)
        reason = Eligibility.vote_blocked_reason(user, election, voter)
        raise Error.new(reason) if reason

        running = election.candidates.running.pluck(:id, :user_id).to_h
        raise Error.new(:invalid_ballot) unless ids.all? { |id| running.key?(id) }
        raise Error.new(:self_vote) if ids.any? { |id| running[id] == user.id }

        ballot = Ballot.find_or_initialize_by(election_id: election.id, user_id: user.id)
        ballot.update!(ranking: ids, weight: voter.weight, ip_address: ip_address)
        ballot
      end
    end

    def self.clear!(user, election)
      election.change_in!(:votes) do
        Ballot.find_by(election_id: election.id, user_id: user.id)&.destroy!
      end
    end

    # A flat list of distinct candidate ids, best first.
    def self.parse(ranking)
      raw = Array(ranking)
      raise Error.new(:invalid_ballot) unless raw.all? { |id| id.to_s.match?(/\A\d+\z/) }
      ids = raw.map(&:to_i)
      raise Error.new(:empty_ballot) if ids.empty?
      raise Error.new(:invalid_ballot) if ids.uniq.size != ids.size
      ids
    end

    def self.void!(ballot, reason, actor)
      reason = reason.to_s.strip
      raise Error.new(:reason_required) if reason.blank?
      with_ballots_open(ballot.election) do
        ballot.update!(
          voided_at: Time.zone.now,
          voided_by: actor,
          void_reason: reason.truncate(500),
        )
      end
      StaffLog.log(
        actor,
        "mod_election_void_ballot",
        user_id: ballot.user_id,
        election_id: ballot.election_id,
        reason: reason,
      )
    end

    def self.restore!(ballot, actor)
      with_ballots_open(ballot.election) do
        ballot.update!(voided_at: nil, voided_by: nil, void_reason: nil)
      end
      StaffLog.log(
        actor,
        "mod_election_restore_ballot",
        user_id: ballot.user_id,
        election_id: ballot.election_id,
      )
    end

    # When voting closes, the ballot of anyone who couldn't vote any more
    # (suspended, silenced, anonymized, deactivated, made an admin, dropped
    # to trust level 0 or out of the groups that can open the page) is set
    # aside, before anyone sees a count. Someone who could vote again by the
    # close keeps theirs. An admin can put one back until the first preview
    # (one a moderator's suspension set aside, say). Nothing goes in the
    # staff log, which moderators can read: it would say who voted.
    def self.set_aside_ineligible!(election, now)
      DB.exec(
        <<~SQL,
          UPDATE jtech_election_ballots b
          SET voided_at = :now, voided_by_id = :by, void_reason = :reason, updated_at = :now
          FROM users u
          WHERE b.election_id = :election_id
            AND b.user_id = u.id
            AND b.voided_at IS NULL
            AND NOT (#{Roll.can_vote_sql("u")})
        SQL
        election_id: election.id,
        now: now,
        by: Discourse::SYSTEM_USER_ID,
        reason: I18n.t("mod_elections.reasons.cannot_vote"),
      )
    end

    # Ballots are set aside, or put back, between the close of voting (so
    # nobody learns during Vote Week who has voted) and the first preview
    # of the count (after which a difference between two previews would
    # show what was on a ballot), under the lock publishing takes.
    def self.with_ballots_open(election)
      election.change_in!(:closed) do
        raise Error.new(:count_previewed) if election.previewed_at.present?
        yield
      end
    end
  end
end
