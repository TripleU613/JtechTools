# frozen_string_literal: true

module DiscourseModElections
  # Moderator rights and trust levels when results are published or a seat
  # is left mid-term.
  module Seats
    # The seats elections are about: everyone with moderator rights who isn't
    # an admin.
    def self.sitting
      User.real.where(moderator: true, admin: false)
    end

    # What publishing these winners would change, before anything does.
    # `problems` are winners who can't take a seat any more (suspended,
    # deactivated, made an admin or deleted since they ran); publishing waits
    # until an admin takes them off the ballot and the count moves on.
    def self.plan(election, elected_ids)
      elected = election.candidates.where(id: elected_ids).includes(:user).to_a
      problems = elected.reject { |c| Eligibility.can_serve?(c.user) }
      winners = (elected - problems).map(&:user)
      winner_ids = winners.map(&:id)
      leaving = sitting.where.not(id: winner_ids).order(:username).to_a
      ran = election.candidates.where(user_id: leaving.map(&:id)).index_by(&:user_id)
      # Everyone's strikes in one query.
      had =
        UserCustomField
          .where(user_id: leaving.map(&:id), name: DiscourseModElections::STRIKES_FIELD)
          .pluck(:user_id, :value)
          .to_h
      {
        join: winners.reject(&:moderator?),
        stay: winners.select(&:moderator?),
        leave:
          leaving.map do |user|
            strike = ran[user.id]&.running? || false
            strikes = had[user.id].to_i + (strike ? 1 : 0)
            {
              user: user,
              strike: strike,
              strikes: strikes,
              trust_level: former_trust_level(strikes),
              # Made a moderator after nominations opened, so never on this
              # ballot: easy to miss that publishing still ends their seat.
              on_ballot: ran.key?(user.id),
            }
          end,
        problems: problems,
      }
    end

    def self.apply!(plan, actor)
      logger = StaffActionLogger.new(actor)
      plan[:join].each do |user|
        user.grant_moderation!
        logger.log_grant_moderation(user)
      end
      (plan[:join] + plan[:stay]).each { |user| seat_trust_level!(user, actor) }
      plan[:leave].each do |row|
        user = row[:user]
        user.revoke_moderation!
        logger.log_revoke_moderation(user)
        set_strikes!(user, row[:strikes]) if row[:strike]
        leave_trust_level!(user, row[:strikes], actor)
      end
    end

    # Someone leaves an elected seat before the next election. Stepping down
    # is like not running again; removal for abuse goes back to trust level
    # 3 whatever the settings say.
    def self.vacate!(candidate, reason, actor)
      raise Error.new(:not_found) if Candidate::SEAT_LEFT_REASONS.exclude?(reason)
      # Under the election's lock, like a countback filling the seat.
      candidate.election.with_lock do
        candidate.reload
        raise Error.new(:not_seated) unless candidate.elected? && candidate.seat_left_at.nil?
        candidate.update!(seat_left_at: Time.zone.now, seat_left_reason: reason)
      end
      # The results page shows who left their seat: open ones reload.
      State.changed!
      user = candidate.user
      StaffLog.log(
        actor,
        "mod_election_vacate",
        user_id: candidate.user_id,
        election_id: candidate.election_id,
        reason: reason,
      )
      # Someone made an admin since keeps their rights and trust level.
      return if user.nil? || user.admin?
      if user.moderator?
        user.revoke_moderation!
        StaffActionLogger.new(actor).log_revoke_moderation(user)
      end
      if reason == "removed"
        back_to_tl3!(user, actor)
      else
        leave_trust_level!(user, strikes(user), actor)
      end
      Nominations.leave_ballots!(user, reason, actor)
    end

    def self.strikes(user)
      user.custom_fields[DiscourseModElections::STRIKES_FIELD].to_i
    end

    def self.set_strikes!(user, count)
      user.custom_fields[DiscourseModElections::STRIKES_FIELD] = count
      user.save_custom_fields(true)
    end

    def self.keep_tl4?(strikes)
      SiteSetting.mod_elections_former_mods_keep_tl4 &&
        strikes < SiteSetting.mod_elections_strikes_before_tl3
    end

    # The trust level a former moderator ends up at, for the plan; nil when
    # elections leave it alone.
    def self.former_trust_level(strikes)
      return unless SiteSetting.mod_elections_former_mods_keep_tl4
      keep_tl4?(strikes) ? TrustLevel[4] : TrustLevel[3]
    end

    def self.seat_trust_level!(user, actor)
      if SiteSetting.mod_elections_former_mods_keep_tl4
        lock_trust_level!(user, TrustLevel[4], actor)
      end
    end

    def self.leave_trust_level!(user, strikes, actor)
      return unless SiteSetting.mod_elections_former_mods_keep_tl4
      keep_tl4?(strikes) ? lock_trust_level!(user, TrustLevel[4], actor) : back_to_tl3!(user, actor)
    end

    def self.lock_trust_level!(user, level, actor)
      user.change_trust_level!(level, log_action_for: actor) if user.trust_level != level
      return if user.manual_locked_trust_level == level
      user.update!(manual_locked_trust_level: level)
      StaffActionLogger.new(actor).log_lock_trust_level(user)
    end

    # Unlocked, so the usual trust level 3 rules apply from here on.
    def self.back_to_tl3!(user, actor)
      unless user.manual_locked_trust_level.nil?
        user.update!(manual_locked_trust_level: nil)
        StaffActionLogger.new(actor).log_lock_trust_level(user)
      end
      if user.trust_level > TrustLevel[3]
        user.change_trust_level!(TrustLevel[3], log_action_for: actor)
      end
    end
  end
end
