# frozen_string_literal: true

# Jtech sub-plugin: Discord chat — a Discord server for general chat that
# only members with a linked JTech account can talk in. The forum stays the
# source of truth: Discord sign-in (core) links the accounts, and this module
# gives linked members the server's member role and their forum username,
# mirrors forum staff into the staff roles, and takes access away from anyone
# suspended, silenced or deactivated here. Nothing from the forum's content
# is sent to Discord.

module ::DiscourseDiscordChat
  LOG_TAG = "[jtech-tools discord-chat]"

  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.discord_chat_enabled
  end

  def self.configured?
    enabled? && SiteSetting.discord_chat_bot_token.present? &&
      SiteSetting.discord_chat_guild_id.to_s.strip.present?
  end

  # Whether a forum account may be in the chat.
  def self.allowed?(user)
    return false if user.nil?
    return false if !user.active || user.staged || user.suspended? || user.silenced?
    return true if user.staff?
    user.trust_level >= SiteSetting.discord_chat_min_trust_level
  end
end

require_relative "../lib/discourse_discord_chat/api"
require_relative "../lib/discourse_discord_chat/member_sync"

after_initialize do
  on(:site_setting_changed) do |name, _old, _new|
    next unless name.to_s.start_with?("discord_chat_")
    next unless DiscourseDiscordChat.configured?
    Jobs.enqueue(:discord_chat_sync_members)
  end
end
