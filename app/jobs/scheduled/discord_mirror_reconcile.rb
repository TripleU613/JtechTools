# frozen_string_literal: true

module Jobs
  # Safety net for changes that don't fire an event we listen to (a post
  # hidden by flags, a topic unlisted or closed, a category made private):
  # re-syncs every mirrored topic whose forum side changed since its last
  # sync, and checks the channel list once an hour.
  class DiscordMirrorReconcile < ::Jobs::Scheduled
    every 10.minutes

    def execute(_args)
      return unless DiscourseDiscordMirror.configured?

      DiscourseDiscordMirror::Backfill.stale_topic_ids.each do |topic_id|
        Jobs.enqueue(:discord_mirror_sync_topic, topic_id: topic_id)
      end

      last = Discourse.redis.get("discord_mirror_structure_at").to_i
      if Time.now.to_i - last > 1.hour.to_i
        Discourse.redis.setex("discord_mirror_structure_at", 2.hours.to_i, Time.now.to_i)
        Jobs.enqueue(:discord_mirror_sync_structure)
      end
    end
  end
end
