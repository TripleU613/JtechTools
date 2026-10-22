# frozen_string_literal: true

module DiscourseModElections
  # The voter list, fixed when nominations open. A vote counts as much as
  # the voter's trust level at that moment, so trust level 0 isn't on it.
  # Admins aren't either: they don't vote. Nor is anyone who can't open the
  # elections page then. A trust level that drops later lowers the vote or
  # takes it away (Standing).
  module Roll
    def self.snapshot!(election, now: Time.zone.now)
      DB.exec(<<~SQL, election_id: election.id, cutoff: now - min_age, now: now)
        INSERT INTO jtech_election_voters (election_id, user_id, weight)
        SELECT :election_id, u.id, u.trust_level
        FROM users u
        WHERE u.id > 0
          AND u.active
          AND NOT u.staged
          AND NOT u.admin
          AND u.trust_level > 0
          AND u.created_at <= :cutoff
          AND (u.suspended_till IS NULL OR u.suspended_till <= :now)
          AND (u.silenced_till IS NULL OR u.silenced_till <= :now)
          AND NOT EXISTS (SELECT 1 FROM anonymous_users a WHERE a.user_id = u.id)
          AND #{can_view_sql("u")}
          AND NOT #{Standing.anonymized_sql("u")}
        ON CONFLICT (election_id, user_id) DO NOTHING
      SQL
    end

    # Eligibility.can_view? as SQL, for `users` under the given alias,
    # before anyone is on the list: a moderator, or a member of
    # mod_elections_view_allowed_groups. Group ids are integers from the
    # setting, so they're safe to inline.
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
