# frozen_string_literal: true

module DiscourseDisteleplus
  module Access
    def self.allowed_group_ids
      SiteSetting.disteleplus_allowed_groups_map.reject(&:zero?).uniq
    end

    def self.allowed?(user)
      return false unless DiscourseDisteleplus.enabled?
      return false if user.nil? || !user.active || user.staged || user.suspended?
      return true if user.admin?

      (user.group_ids & allowed_group_ids).any?
    end

    def self.moderator?(user)
      allowed?(user) && user.staff?
    end

    def self.allowed_users
      group_user_ids = GroupUser.where(group_id: allowed_group_ids).select(:user_id)
      User
        .real
        .activated
        .not_suspended
        .not_silenced
        .not_staged
        .where("users.admin OR users.id IN (?)", group_user_ids)
        .distinct
    end

    def self.can_edit?(user, message)
      return false unless allowed?(user) && message&.source_discourse? && !message.deleted?
      message.user_id == user.id || moderator?(user)
    end

    # Unlike editing (a bot can't edit somebody else's Telegram message), a
    # message written on Telegram can be deleted here: the bot deletes it
    # there too. Its author, as matched to a forum account, or staff.
    def self.can_delete?(user, message)
      return false unless allowed?(user) && message && !message.deleted?
      message.user_id == user.id || moderator?(user)
    end
  end
end
