# frozen_string_literal: true

module DiscourseReqpm
  # Who may use REQ-PM and who may reach whom. Staff get no extra reach
  # here on purpose: an admin can neither read anyone's card nor bypass
  # someone's ignore/mute or "no requests" choice.
  module Policy
    # A real, active, human account in one of the allowed groups.
    def self.can_use?(user)
      return false unless DiscourseReqpm.enabled?
      return false if user.nil? || user.id.to_i <= 0
      return false if user.staged? || !user.active? || user.suspended? || user.silenced?
      # Anonymous-mode shadow accounts: exchanging contact details would
      # defeat the point of posting anonymously.
      return false if user.anonymous?
      user.in_any_groups?(SiteSetting.reqpm_allowed_groups_map)
    end

    def self.allows_requests?(user)
      raw = user.custom_fields[DiscourseReqpm::ALLOW_REQUESTS_FIELD]
      raw.nil? ? true : ActiveModel::Type::Boolean.new.cast(raw)
    end

    # Why `actor` cannot send `target` a request (or their own details), or
    # nil when they can. Reasons shown to the actor are deliberately coarse —
    # "unavailable" covers ignored/muted, a user who turned requests off, and
    # a user who can't use REQ-PM — so nobody can probe which one applies.
    def self.blocked_reason(actor, target, for_request:)
      return :self if actor.id == target.id
      return :unavailable unless can_use?(target)
      return :unavailable if for_request && !allows_requests?(target)
      return :unavailable if ignoring_or_muting?(target, actor)
      nil
    end

    # Checked directly rather than through UserCommScreener, which lets
    # staff through regardless: here an ignore or mute stops everyone.
    def self.ignoring_or_muting?(user, other)
      MutedUser.exists?(user_id: user.id, muted_user_id: other.id) ||
        IgnoredUser
          .where(user_id: user.id, ignored_user_id: other.id)
          .where("expiring_at > ?", Time.zone.now)
          .exists?
    end
  end
end
