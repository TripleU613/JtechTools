# frozen_string_literal: true

module DiscourseModElections
  # Keeps an open election's voter list and ballot in line with who people
  # are now. Until voting closes:
  #
  # - A vote counts at the voter's trust level now at most, ballot
  #   included. Below trust level 1, out of the groups that can open the
  #   elections page, or anonymized, the voter comes off the list and their
  #   ballot goes.
  # - A candidate below mod_elections_candidate_min_trust_level is taken off
  #   the ballot with that as the reason (sitting moderators run whatever
  #   their level); an admin can put them back. An anonymized candidate
  #   drops out, like a deleted one.
  #
  # A rise changes nothing: the list is fixed when nominations open, so
  # nobody can be levelled up into a bigger vote. Once voting has closed the
  # ballots are fixed for the count and this leaves them alone.
  #
  # The tick runs it every minute, which also catches anything that changed
  # while the module was off; a trust level change or an anonymized account
  # runs it at once for that person.
  module Standing
    def self.check_user!(user)
      Election
        .where(status: Election::BEFORE_CLOSE)
        .order(:id)
        .each { |election| check!(election, user_id: user.id) }
    end

    def self.check!(election, user_id: nil)
      taken_off = []
      changed = false
      election.with_lock do
        next unless election.before_close?
        params = { election_id: election.id, user_id: user_id }
        changed = fix_voters!(params)
        dropped = DB.query_single(<<~SQL, params)
          UPDATE jtech_election_candidates c SET status = #{Candidate.statuses[:withdrawn]}, updated_at = NOW()
          FROM users u
          WHERE #{candidates_where} AND #{anonymized_sql("u")}
          RETURNING c.id
        SQL
        taken_off = disqualify_below_min!(params)
        changed ||= dropped.any? || taken_off.any?
      end
      return unless changed
      taken_off.each do |candidate_user_id, reason|
        StaffLog.log(
          Discourse.system_user,
          "mod_election_disqualify",
          user_id: candidate_user_id,
          election_id: election.id,
          reason: reason,
        )
      end
      Notifier.notify(taken_off.map(&:first), election, "trust_level_dropped") if taken_off.any?
      State.changed!
    end

    def self.fix_voters!(params)
      gone = DB.query_single(<<~SQL, params)
        DELETE FROM jtech_election_voters v
        USING users u
        WHERE #{voters_where}
          AND (u.trust_level < 1 OR NOT #{Roll.can_view_sql("u")} OR #{anonymized_sql("u")})
        RETURNING v.user_id
      SQL
      Ballot.where(election_id: params[:election_id], user_id: gone).delete_all if gone.any?
      lowered = DB.exec(<<~SQL, params)
        UPDATE jtech_election_voters v SET weight = u.trust_level
        FROM users u
        WHERE #{voters_where} AND v.weight > u.trust_level
      SQL
      DB.exec(<<~SQL, params)
        UPDATE jtech_election_ballots b SET weight = u.trust_level
        FROM users u
        WHERE b.election_id = :election_id AND b.user_id = u.id
          AND (:user_id::int IS NULL OR u.id = :user_id)
          AND b.weight > u.trust_level
      SQL
      gone.any? || lowered > 0
    end

    def self.disqualify_below_min!(params)
      reason = I18n.t("mod_elections.reasons.trust_level")
      user_ids = DB.query_single(<<~SQL, params.merge(min: min_trust_level, reason: reason))
        UPDATE jtech_election_candidates c
        SET status = #{Candidate.statuses[:disqualified]}, disqualified_reason = :reason,
            disqualified_by_id = NULL, updated_at = NOW()
        FROM users u
        WHERE #{candidates_where} AND NOT c.incumbent AND NOT u.moderator
          AND u.trust_level < :min
        RETURNING c.user_id
      SQL
      user_ids.map { |user_id| [user_id, reason] }
    end

    def self.voters_where
      <<~SQL.squish
        v.election_id = :election_id AND v.user_id = u.id
        AND (:user_id::int IS NULL OR u.id = :user_id)
      SQL
    end

    def self.candidates_where
      <<~SQL.squish
        c.election_id = :election_id AND c.user_id = u.id
        AND c.status = #{Candidate.statuses[:running]}
        AND (:user_id::int IS NULL OR u.id = :user_id)
      SQL
    end

    # Core's "anonymize user" keeps the account active, at its trust level,
    # under an anonNNNNNNNN name; only its primary email gives it away.
    def self.anonymized_sql(users)
      <<~SQL.squish
        EXISTS (
          SELECT 1 FROM user_emails e
          WHERE e.user_id = #{users}.id AND e.primary
            AND e.email LIKE '%#{UserAnonymizer::EMAIL_SUFFIX}'
        )
      SQL
    end

    def self.anonymized?(user)
      user.primary_email&.email.to_s.end_with?(UserAnonymizer::EMAIL_SUFFIX)
    end

    def self.min_trust_level
      SiteSetting.mod_elections_candidate_min_trust_level.to_i
    end
  end
end
