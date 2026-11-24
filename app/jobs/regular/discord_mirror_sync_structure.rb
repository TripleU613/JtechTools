# frozen_string_literal: true

module Jobs
  # Matches the Discord channels to the forum's public categories.
  class DiscordMirrorSyncStructure < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(_args)
      return unless DiscourseDiscordMirror.configured?
      DistributedMutex.synchronize("discord_mirror_structure", validity: 10.minutes) do
        DiscourseDiscordMirror::Structure.reconcile
      end
    rescue DiscourseDiscordMirror::Api::RateLimited => e
      Jobs.enqueue_in(e.retry_after.seconds, :discord_mirror_sync_structure)
    rescue DiscourseDiscordMirror::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordMirror::LOG_TAG} structure: #{e.message}")
    end
  end
end
