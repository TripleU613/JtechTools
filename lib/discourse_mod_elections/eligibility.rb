# frozen_string_literal: true

module DiscourseModElections
  # Who can run and who can vote. Every check returns why not, or nil.
  module Eligibility
    # A real, active member in good standing right now.
    def self.member?(user)
      return false unless account?(user)
      !user.suspended? && !user.silenced? && !anonymized?(user)
    end

    # A real, active account: not a visitor, staged or an anonymous-mode
    # shadow.
    def self.account?(user)
      return false if user.nil? || user.id.to_i <= 0
      return false if user.staged? || !user.active?
      !user.anonymous?
    end

    # Anonymizing leaves an account active, so the staff log is what says.
    def self.anonymized?(user)
      anonymized_ids([user.id]).any?
    end

    def self.anonymized_ids(user_ids)
      UserHistory
        .where(action: UserHistory.actions[:anonymize_user], target_user_id: user_ids)
        .distinct
        .pluck(:target_user_id)
        .to_set
    end

    # Someone who may hold a seat: a member in good standing who isn't an
    # admin. Checked again when results are published and at a countback.
    def self.can_serve?(user)
      member?(user) && !user.admin?
    end

    # Who can open the elections page: staff, and members of
    # mod_elections_view_allowed_groups (trust level 1 by default). Never a
    # visitor.
    def self.can_view?(user)
      return false if user.nil? || user.id.to_i <= 0
      return true if user.staff?
      user.in_any_groups?(SiteSetting.mod_elections_view_allowed_groups_map)
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

    # Being on the voter list isn't enough: a voter has to qualify for it
    # still, so one suspended, anonymized, made an admin or a moderator or
    # dropped to trust level 0 (or out of the groups that can open the page)
    # since can't vote. Sitting moderators don't vote: they're on the ballot.
    def self.vote_blocked_reason(user, election, voter, now: Time.zone.now)
      return :not_voting unless election.taking_votes?(now)
      return :not_allowed unless member?(user) && can_view?(user)
      return :admin if user.admin?
      return :moderator if user.moderator?
      return :not_on_roll if voter.nil?
      return :not_allowed if user.trust_level < TrustLevel[1]
      nil
    end

    # vote_blocked_reason's rules for the account alone, for someone on the
    # voter list.
    def self.can_vote?(user)
      member?(user) && can_view?(user) && !user.admin? && !user.moderator? &&
        user.trust_level >= TrustLevel[1]
    end

    # The candidates (users loaded) who couldn't stay on the ballot now,
    # for many at once: run_blocked_reason's rules for someone already
    # running. Only an admin's suspension or silence counts (the system's
    # automatic ones are an admin's too): sitting moderators are candidates,
    # and a moderator mustn't be able to knock a rival off the ballot. The
    # admin's preview still won't seat someone a moderator suspended.
    def self.cannot_stay(candidates, now: Time.zone.now)
      ids = candidates.filter_map(&:user_id)
      return [] if ids.empty?
      anonymized = anonymized_ids(ids)
      viewers = User.where(id: ids).where(Roll.can_view_sql("users")).pluck(:id).to_set
      days = SiteSetting.mod_elections_candidate_clean_record_days
      punished =
        if days > 0
          recent_punishments(now, days).where(target_user_id: ids).distinct.pluck(:target_user_id)
        else
          []
        end
      min_trust_level = SiteSetting.mod_elections_candidate_min_trust_level.to_i
      min_age = SiteSetting.mod_elections_candidate_min_account_age_days.days

      candidates.select do |candidate|
        user = candidate.user
        next false if user.nil?
        next true if !account?(user) || user.admin? || anonymized.include?(user.id)
        next true if punished_by_admin?(user) || viewers.exclude?(user.id)
        next false if user.moderator? || candidate.incumbent
        user.trust_level < min_trust_level || user.created_at > now - min_age ||
          punished.include?(user.id)
      end
    end

    # Suspended or silenced now, by anyone but a moderator. With no staff
    # log entry (set from the console, say) it counts.
    def self.punished_by_admin?(user)
      (user.suspended? && !by_moderator?(user.suspend_record)) ||
        (user.silenced? && !by_moderator?(user.silenced_record))
    end

    def self.by_moderator?(entry)
      actor = entry&.acting_user
      actor.present? && !actor.admin?
    end

    # Everyone who could run now and has no place on this ballot yet (on it,
    # dropped out or taken off), for the invitation to run: the rules of
    # run_blocked_reason, in one query.
    def self.could_run(election, now: Time.zone.now)
      # Without the NULLs (deleted accounts), or NOT IN would match nobody.
      on_ballot = election.candidates.where.not(user_id: nil).select(:user_id)
      anonymized =
        UserHistory
          .where(action: UserHistory.actions[:anonymize_user])
          .where.not(target_user_id: nil)
          .select(:target_user_id)
      members =
        User
          .real
          .activated
          .not_staged
          .where(admin: false)
          .where("users.suspended_till IS NULL OR users.suspended_till <= ?", now)
          .where("users.silenced_till IS NULL OR users.silenced_till <= ?", now)
          .where.not(id: on_ballot)
          .where.not(id: anonymized)
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
