# frozen_string_literal: true

module Jobs
  # Puts the slash commands in the Discord server, or takes them all out
  # when commands are off. Discord's bulk overwrite replaces the server's
  # whole list, so running it again is harmless.
  class DiscordChatRegisterCommands < ::Jobs::Base
    def execute(_args)
      return if !DiscourseDiscordChat.configured?

      application_id = SiteSetting.discord_client_id.to_s.strip
      if application_id.blank?
        Rails.logger.warn(
          "#{DiscourseDiscordChat::LOG_TAG} commands: discord_client_id is blank, nothing registered",
        )
        return
      end

      guild_id = SiteSetting.discord_chat_guild_id.to_s.strip
      commands = DiscourseDiscordChat::Commands.definitions

      DiscourseDiscordChat::Api.new.bot(
        :put,
        "/applications/#{application_id}/guilds/#{guild_id}/commands",
        commands,
      )
    rescue DiscourseDiscordChat::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} commands: #{e.message}")
    end
  end
end
