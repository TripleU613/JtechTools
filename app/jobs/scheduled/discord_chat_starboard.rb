# frozen_string_literal: true

module Jobs
  # Looks for newly starred messages in the server's listed channels.
  class DiscordChatStarboard < ::Jobs::Scheduled
    every 2.minutes

    def execute(_args)
      return unless DiscourseDiscordChat.configured?
      return if SiteSetting.discord_chat_starboard_channel_id.to_s.strip.blank?
      DistributedMutex.synchronize("discord_chat_starboard", validity: 2.minutes) do
        DiscourseDiscordChat::Starboard.new.run
      end
    rescue DiscourseDiscordChat::Api::RateLimited
      nil
    rescue DiscourseDiscordChat::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} starboard: #{e.message}")
    end
  end
end
