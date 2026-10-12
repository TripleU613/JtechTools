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

    def self.run_blocked_reason(user, election, now: Time.zone.now)
      return :not_nominating unless election.taking_nominations?(now)
      return :not_allowed unless member?(user)
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

    def self.recently_punished?(user, now)
      days = SiteSetting.mod_elections_candidate_clean_record_days
      return false if days.zero?
      UserHistory
        .where(target_user_id: user.id)
        .where(action: [UserHistory.actions[:suspend_user], UserHistory.actions[:silence_user]])
        .where("created_at >= ?", now - days.days)
        .exists?
    end
  end
end
