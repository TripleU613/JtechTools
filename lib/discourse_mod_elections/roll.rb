# frozen_string_literal: true

module DiscourseModElections
  # The voter list, fixed when nominations open. A vote counts as much as
  # the voter's trust level at that moment, so trust level 0 isn't on it.
  # Admins aren't either: they don't vote. Nor are sitting moderators with
  # mod_elections_moderators_cannot_vote on. Only people who can open the
  # elections page then are on it. Someone who stops qualifying during the
  # election loses their vote (Eligibility.vote_blocked_reason and
  # Voting.set_aside_ineligible!).
  module Roll
    def self.snapshot!(election, now: Time.zone.now)
      DB.exec(<<~SQL, election_id: election.id, cutoff: now - min_age, now: now)
        INSERT INTO jtech_election_voters (election_id, user_id, weight)
        SELECT :election_id, u.id, u.trust_level
        FROM users u
        WHERE #{can_vote_sql("u")}
          AND u.created_at <= :cutoff
        ON CONFLICT (election_id, user_id) DO NOTHING
      SQL
    end

    # Who can vote right now, as SQL for `users` under the given alias (bind
    # :now): what the voter list asks of an account, its age aside.
    def self.can_vote_sql(users)
      <<~SQL.squish
        #{users}.id > 0
        AND #{users}.active
        AND NOT #{users}.staged
        AND NOT #{users}.admin
        #{Eligibility.moderators_vote? ? "" : "AND NOT #{users}.moderator"}
        AND #{users}.trust_level > 0
        AND (#{users}.suspended_till IS NULL OR #{users}.suspended_till <= :now)
        AND (#{users}.silenced_till IS NULL OR #{users}.silenced_till <= :now)
        AND NOT EXISTS (SELECT 1 FROM anonymous_users a WHERE a.user_id = #{users}.id)
        AND NOT EXISTS (
          SELECT 1 FROM user_histories h
          WHERE h.target_user_id = #{users}.id
            AND h.action = #{UserHistory.actions[:anonymize_user].to_i}
        )
        AND #{can_view_sql(users)}
      SQL
    end

    # Eligibility.can_view? as SQL, for `users` under the given alias: a
    # moderator, or a member of mod_elections_view_allowed_groups. Group ids
    # are integers from the setting, so they're safe to inline.
    def self.can_view_sql(users)
      ids = SiteSetting.mod_elections_view_allowed_groups_map.map(&:to_i)
      return "TRUE" if ids.include?(Group::AUTO_GROUPS[:everyone])
      return "#{users}.moderator" if ids.empty?
      <<~SQL.squish
        (#{users}.moderator OR EXISTS (
          SELECT 1 FROM group_users gu
          WHERE gu.user_id = #{users}.id AND gu.group_id IN (#{ids.join(",")})
        ))
      SQL
    end

    def self.min_age
      SiteSetting.mod_elections_voter_min_account_age_days.days
    end
  end
end
