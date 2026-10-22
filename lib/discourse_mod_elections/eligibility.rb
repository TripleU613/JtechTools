# frozen_string_literal: true

module DiscourseModElections
  # Who can run and who can vote. Every check returns why not, or nil.
  module Eligibility
    # A real, active member in good standing right now.
    def self.member?(user)
      return false if user.nil? || user.id.to_i <= 0
      return false if user.staged? || !user.active? || user.suspended? || user.silenced?
      !user.anonymous?
    end

    # Someone who may hold a seat: a member in good standing who isn't an
    # admin. Checked again when results are published and at a countback.
    def self.can_serve?(user)
      member?(user) && !user.admin?
    end

    # Who can open the elections page: staff, members of
    # mod_elections_view_allowed_groups (trust level 1 by default), and
    # anyone on the voter list or the ballot of the election under way. The
    # list is fixed when nominations open, so a trust level that drops since
    # (or a group they leave) mustn't take away the vote they were given.
    # Never a visitor.
    def self.can_view?(user)
      return false if user.nil? || user.id.to_i <= 0
      return true if user.staff?
      return true if user.in_any_groups?(SiteSetting.mod_elections_view_allowed_groups_map)
      taking_part?(user)
    end

    def self.taking_part?(user)
      active = State.active
      return false if active.nil?
      Voter.where(election_id: active[:id], user_id: user.id).exists? ||
        Candidate.where(election_id: active[:id], user_id: user.id).exists?
    end

    def self.run_blocked_reason(user, election, now: Time.zone.now)
      return :not_nominating unless election.taking_nominations?(now)
      return :not_allowed unless member?(user) && can_view?(user)
      return :admin if user.admin?

      candidate = election.candidates.find_by(user_id: user.id)
      return :disqualified if candidate&.disqualified?
      return :already_running if candidate&.running?
      # Sitting moderators were on the ballot already; one who dropped out
      # can change their mind whatever their trust level.
      return if user.moderator? || candidate&.incumbent

      if user.trust_level < SiteSetting.mod_elections_candidate_min_trust_level.to_i
        return :trust_level
      end
      min_age = SiteSetting.mod_elections_candidate_min_account_age_days
      return :account_age if user.created_at > now - min_age.days
      return :record if recently_punished?(user, now)
      nil
    end

    def self.vote_blocked_reason(user, election, voter, now: Time.zone.now)
      return :not_voting unless election.taking_votes?(now)
      return :not_allowed unless member?(user)
      return :admin if user.admin?
      return :not_on_roll if voter.nil?
      nil
    end

    # Everyone who could run now and has no place on this ballot yet (on it,
    # dropped out or taken off), for the invitation to run: the rules of
    # run_blocked_reason, in one query.
    def self.could_run(election, now: Time.zone.now)
      # Without the NULLs (deleted accounts), or NOT IN would match nobody.
      on_ballot = election.candidates.where.not(user_id: nil).select(:user_id)
      members =
        User
          .real
          .activated
          .not_staged
          .where(admin: false)
          .where("users.suspended_till IS NULL OR users.suspended_till <= ?", now)
          .where("users.silenced_till IS NULL OR users.silenced_till <= ?", now)
          .where.not(id: on_ballot)
          .where(Roll.can_view_sql("users"))
      min_age = SiteSetting.mod_elections_candidate_min_account_age_days.days
      qualified =
        members.where(
          "users.trust_level >= ? AND users.created_at <= ?",
          SiteSetting.mod_elections_candidate_min_trust_level.to_i,
          now - min_age,
        )
      days = SiteSetting.mod_elections_candidate_clean_record_days
      if days > 0
        punished = recent_punishments(now, days).where.not(target_user_id: nil)
        qualified = qualified.where.not(id: punished.select(:target_user_id))
      end
      qualified.or(members.where(moderator: true))
    end

    # Suspensions and silences, from the staff log.
    def self.punishments
      UserHistory.where(
        action: [UserHistory.actions[:suspend_user], UserHistory.actions[:silence_user]],
      )
    end

    # Only an admin's suspension or silence counts (the system's automatic
    # ones are an admin's too): sitting moderators are candidates, and a
    # minute's silence mustn't keep a rival off the ballot for months.
    def self.recent_punishments(now, days)
      by_admins = punishments.where(acting_user_id: User.where(admin: true).select(:id))
      by_admins.where("user_histories.created_at >= ?", now - days.days)
    end

    def self.recently_punished?(user, now)
      days = SiteSetting.mod_elections_candidate_clean_record_days
      return false if days.zero?
      recent_punishments(now, days).where(target_user_id: user.id).exists?
    end
  end
end
