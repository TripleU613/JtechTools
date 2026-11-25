# frozen_string_literal: true

module Jobs
  # Gives the Discord chat's roles and nicknames to the members whose forum
  # account allows it, and takes them from those it no longer allows.
  class DiscordChatSyncMembers < ::Jobs::Scheduled
    every 1.minute

    def execute(_args)
      return unless DiscourseDiscordChat.configured?
      DistributedMutex.synchronize("discord_chat_sync_members", validity: 2.minutes) do
        DiscourseDiscordChat::MemberSync.new.run
      end
    rescue DiscourseDiscordChat::Api::RateLimited
      # The next run picks up where this one stopped.
      nil
    rescue DiscourseDiscordChat::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} sync: #{e.message}")
    end
  end
end
