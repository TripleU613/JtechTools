# frozen_string_literal: true

module DiscourseModElections
  # A trust level that drops during nominations or Vote Week takes back what
  # it gave. The vote counts at the new level at most, ballot included, and
  # below trust level 1, or out of the groups that can open the elections
  # page, the voter comes off the list and their ballot goes. A candidate
  # below mod_elections_candidate_min_trust_level is taken off the ballot
  # (sitting moderators run whatever their level); an admin can put them
  # back. A rise changes nothing: the list is fixed when nominations open,
  # so nobody can be levelled up into a bigger vote. Once voting has closed
  # the ballots are fixed for the count and this leaves them alone.
  module TrustDrop
    def self.apply!(user, new_level)
      dropped = []
      Election
        .where(status: Election::BEFORE_CLOSE)
        .order(:id)
        .each do |election|
          election.with_lock do
            next unless election.before_close?
            drop_vote!(election, user, new_level)
            dropped << election if drop_candidacy!(election, user, new_level)
          end
        end
      dropped.each { |election| Notifier.notify([user.id], election, "trust_level_dropped") }
      State.changed! if dropped.any?
    end

    def self.drop_vote!(election, user, level)
      voter = Voter.find_by(election_id: election.id, user_id: user.id)
      return if voter.nil?
      ballots = Ballot.where(election_id: election.id, user_id: user.id)
      if level < 1 || !can_view_at?(user, level)
        voter.destroy!
        ballots.delete_all
      elsif level < voter.weight
        voter.update!(weight: level)
        ballots.update_all(weight: level)
      end
    end

    def self.drop_candidacy!(election, user, level)
      min = SiteSetting.mod_elections_candidate_min_trust_level.to_i
      return false if level >= min || user.moderator?
      candidate = election.candidates.running.find_by(user_id: user.id, incumbent: false)
      return false if candidate.nil?
      reason = I18n.t("mod_elections.reasons.trust_level")
      candidate.update!(status: :disqualified, disqualified_reason: reason, disqualified_by: nil)
      StaffLog.log(
        Discourse.system_user,
        "mod_election_disqualify",
        user_id: user.id,
        election_id: election.id,
        reason: reason,
      )
      true
    end

    # Eligibility.can_view? at the new level. Core fires :user_promoted
    # before it moves the user between the trust level groups, so those are
    # judged by the level; other groups don't change with it.
    def self.can_view_at?(user, level)
      return true if user.staff?
      ids = SiteSetting.mod_elections_view_allowed_groups_map
      return true if ids.include?(Group::AUTO_GROUPS[:everyone])
      levels = (0..4).index_by { |n| Group::AUTO_GROUPS[:"trust_level_#{n}"] }
      return true if ids.any? { |id| levels.key?(id) && level >= levels[id] }
      others = ids - levels.keys
      others.any? && user.in_any_groups?(others)
    end
  end
end
