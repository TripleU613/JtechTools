# frozen_string_literal: true

module DiscourseModElections
  # The voter list, fixed when nominations open. A vote counts as much as
  # the voter's trust level at that moment, so trust level 0 isn't on it.
  # Admins aren't either: they don't vote.
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
        ON CONFLICT (election_id, user_id) DO NOTHING
      SQL
    end

    def self.min_age
      SiteSetting.mod_elections_voter_min_account_age_days.days
    end
  end
end
