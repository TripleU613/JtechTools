# frozen_string_literal: true

module Jobs
  # Mirrors one topic into Discord. Re-enqueues itself while a long topic is
  # still being sent, and waits out Discord's rate limits.
  class DiscordMirrorSyncTopic < ::Jobs::Base
    sidekiq_options queue: "low"

    def execute(args)
      return unless DiscourseDiscordMirror.configured?
      topic_id = args[:topic_id].to_i
      return if topic_id <= 0

      result = DiscourseDiscordMirror::TopicSync.new(topic_id).run
      Jobs.enqueue_in(2.seconds, :discord_mirror_sync_topic, topic_id: topic_id) if result == :more
    rescue DiscourseDiscordMirror::Api::RateLimited => e
      Jobs.enqueue_in(e.retry_after.seconds, :discord_mirror_sync_topic, topic_id: topic_id)
    rescue DiscourseDiscordMirror::Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordMirror::LOG_TAG} topic #{topic_id}: #{e.message}")
    end
  end
end
