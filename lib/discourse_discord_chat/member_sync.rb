# frozen_string_literal: true

module DiscourseDiscordChat
  # Keeps the Discord server's people in line with their forum accounts:
  # members who linked Discord on the forum get the member role and their
  # forum username as nickname, forum staff get the staff roles, and anyone
  # unlinked, suspended, silenced or deactivated has those roles taken away.
  # Trust levels, groups and chosen badges can each have a role too. The
  # forum decides; the one thing read back from Discord is the Supporter
  # role bought in the server shop, which adds the member to a forum group.
  class MemberSync
    PAGE = 1000

    # Waits this long at most for one rate limit before giving the rest of
    # the run up to the next one.
    MAX_WAIT = 10

    def initialize(api: Api.new, sleeper: ->(seconds) { sleep(seconds) })
      @api = api
      @sleeper = sleeper
      @groups = {}
      @badges = {}
    end

    def run
      guild = call(:get, "/guilds/#{guild_id}")
      members = all_members
      links = linked_users(members.map { |m| m.dig("user", "id") })
      preload(links.values)

      members.each do |member|
        next if member.dig("user", "bot")
        sync_member(member, links[member.dig("user", "id")], owner_id: guild["owner_id"])
      end
    end

    def sync_member(member, user, owner_id:)
      discord_id = member.dig("user", "id")
      allowed = DiscourseDiscordChat.allowed?(user)
      has = member["roles"] || []

      add_supporter(user) if user && has.include?(supporter_role_id)

      managed_roles.each do |role_id, tests|
        want = allowed && tests.any? { |wanted| wanted.call(user) }
        if want && !has.include?(role_id)
          call(:put, "/guilds/#{guild_id}/members/#{discord_id}/roles/#{role_id}")
        elsif !want && has.include?(role_id)
          call(:delete, "/guilds/#{guild_id}/members/#{discord_id}/roles/#{role_id}")
        end
      end

      # Discord doesn't let anyone rename the server's owner.
      return if discord_id == owner_id
      return unless allowed && SiteSetting.discord_chat_sync_nicknames
      return if member["nick"] == user.username
      call(:patch, "/guilds/#{guild_id}/members/#{discord_id}", { nick: user.username })
    rescue Api::RateLimited
      raise
    rescue Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} member #{discord_id}: #{e.message}")
    end

    private

    # A launch can link many people at once; a short rate limit is waited
    # out instead of ending the run.
    def call(*args, **kwargs)
      attempts = 0
      begin
        @api.bot(*args, **kwargs)
      rescue Api::RateLimited => e
        attempts += 1
        raise if attempts > 3 || e.retry_after > MAX_WAIT
        @sleeper.call(e.retry_after)
        retry
      end
    end

    def guild_id
      SiteSetting.discord_chat_guild_id.to_s.strip
    end

    # role id => who should have it, for the roles the forum manages. A role
    # listed more than once goes to anyone any of its entries picks.
    def managed_roles
      @managed_roles ||=
        begin
          roles = Hash.new { |hash, key| hash[key] = [] }
          roles[SiteSetting.discord_chat_member_role_id] << ->(_user) { true }
          roles[SiteSetting.discord_chat_moderator_role_id] << ->(user) { user.staff? }
          roles[SiteSetting.discord_chat_admin_role_id] << ->(user) { user.admin? }
          pairs(SiteSetting.discord_chat_trust_level_roles).each do |level, role_id|
            roles[role_id] << ->(user) { user.trust_level == level.to_i }
          end
          group_ids = Group.where(name: pairs(SiteSetting.discord_chat_group_roles).map(&:first))
          group_ids = group_ids.pluck(:name, :id).to_h
          pairs(SiteSetting.discord_chat_group_roles).each do |name, role_id|
            id = group_ids[name]
            roles[role_id] << ->(user) { @groups[user.id]&.include?(id) } if id
          end
          pairs(SiteSetting.discord_chat_badge_roles).each do |badge_id, role_id|
            roles[role_id] << ->(user) { @badges[user.id]&.include?(badge_id.to_i) }
          end
          roles.transform_keys { |id| id.to_s.strip }.reject { |id, _| id.blank? }
        end
    end

    # "key:role id" entries of a list setting
    def pairs(value)
      value
        .to_s
        .split("|")
        .filter_map do |entry|
          key, role_id = entry.split(":", 2).map { |part| part.to_s.strip }
          [key, role_id] if key.present? && role_id.present?
        end
    end

    # Group and badge lookups for every linked member at once.
    def preload(users)
      ids = users.compact.map(&:id)
      @groups = GroupUser.where(user_id: ids).pluck(:user_id, :group_id).group_by(&:first)
      @groups.transform_values! { |rows| rows.map(&:last).to_set }
      badge_ids = pairs(SiteSetting.discord_chat_badge_roles).map { |id, _| id.to_i }
      @badges =
        UserBadge
          .where(user_id: ids, badge_id: badge_ids)
          .distinct
          .pluck(:user_id, :badge_id)
          .group_by(&:first)
      @badges.transform_values! { |rows| rows.map(&:last).to_set }
    end

    def supporter_role_id
      SiteSetting.discord_chat_supporter_role_id.to_s.strip.presence
    end

    # Buying the Supporter product is permanent, so the group is only ever
    # added to, never taken away here.
    def add_supporter(user)
      return if supporter_role_id.nil?
      group = supporter_group
      return if group.nil? || @groups[user.id]&.include?(group.id)
      group.add(user)
      (@groups[user.id] ||= Set.new) << group.id
    end

    def supporter_group
      return @supporter_group if defined?(@supporter_group)
      name = SiteSetting.discord_chat_supporter_group.to_s.strip
      @supporter_group = name.present? ? Group.find_by(name: name) : nil
    end

    def all_members
      members = []
      after = "0"
      loop do
        page = call(:get, "/guilds/#{guild_id}/members", query: { limit: PAGE, after: after }) || []
        members.concat(page)
        break if page.size < PAGE
        after = page.last.dig("user", "id")
      end
      members
    end

    def linked_users(discord_ids)
      UserAssociatedAccount
        .where(provider_name: "discord", provider_uid: discord_ids.compact)
        .where.not(user_id: nil)
        .includes(:user)
        .to_h { |link| [link.provider_uid, link.user] }
    end
  end
end
