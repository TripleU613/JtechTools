# frozen_string_literal: true

module Jobs
  # Sends existing topics to Discord, oldest activity first, so the newest end
  # up on top of each Discord forum channel. Works in short slices and keeps
  # its place, so it survives restarts and rate limits.
  class DiscordMirrorBackfill < ::Jobs::Base
    sidekiq_options queue: "low"

    SLICE = 45.seconds

    def execute(_args)
      return unless DiscourseDiscordMirror.configured?
      days = SiteSetting.discord_mirror_backfill_days.to_i
      return if days <= 0

      started = Time.now
      DistributedMutex.synchronize("discord_mirror_backfill", validity: 2.minutes) do
        DiscourseDiscordMirror::Backfill
          .topics(days)
          .each do |topic|
            if Time.now - started > SLICE
              Jobs.enqueue_in(1.second, :discord_mirror_backfill)
              return
            end

            loop do
              result = DiscourseDiscordMirror::TopicSync.new(topic.id, archive_when_quiet: true).run
              break if result == :done
            end
            DiscourseDiscordMirror::Backfill.advance(topic)
          end
        DiscourseDiscordMirror::Backfill.finish
      end
    rescue DiscourseDiscordMirror::Api::RateLimited => e
      Jobs.enqueue_in(e.retry_after.seconds, :discord_mirror_backfill)
    rescue DiscourseDiscordMirror::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordMirror::LOG_TAG} backfill: #{e.message}")
      Jobs.enqueue_in(1.minute, :discord_mirror_backfill)
    end
  end
end
