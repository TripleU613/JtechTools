# frozen_string_literal: true

module DiscourseDiscordChat
  # Keeps the Discord server's people in line with their forum accounts:
  # members who linked Discord on the forum get the member role and their
  # forum username as nickname, forum staff get the staff roles, and anyone
  # unlinked, suspended, silenced or deactivated has those roles taken away.
  # The forum decides; nothing is read back from Discord.
  class MemberSync
    PAGE = 1000

    # Waits this long at most for one rate limit before giving the rest of
    # the run up to the next one.
    MAX_WAIT = 10

    def initialize(api: Api.new, sleeper: ->(seconds) { sleep(seconds) })
      @api = api
      @sleeper = sleeper
    end

    def run
      guild = call(:get, "/guilds/#{guild_id}")
      members = all_members
      links = linked_users(members.map { |m| m.dig("user", "id") })

      members.each do |member|
        next if member.dig("user", "bot")
        sync_member(member, links[member.dig("user", "id")], owner_id: guild["owner_id"])
      end
    end

    def sync_member(member, user, owner_id:)
      discord_id = member.dig("user", "id")
      allowed = DiscourseDiscordChat.allowed?(user)
      has = member["roles"] || []

      managed_roles.each do |role_id, wanted|
        want = allowed && wanted.call(user)
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

    # role id => who should have it, for the roles the forum manages
    def managed_roles
      {
        SiteSetting.discord_chat_member_role_id => ->(_user) { true },
        SiteSetting.discord_chat_moderator_role_id => ->(user) { user.staff? },
        SiteSetting.discord_chat_admin_role_id => ->(user) { user.admin? },
      }.transform_keys { |id| id.to_s.strip }.reject { |id, _| id.blank? }
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
