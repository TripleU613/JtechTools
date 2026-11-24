# frozen_string_literal: true

# Jtech sub-plugin: Discord mirror — a live, read-only copy of the forum's
# public categories in a Discord server. Each category is a Discord forum
# channel, each topic a thread, each post a message under the author's name
# and avatar. Only what a logged-out visitor can read is sent, and anything
# that stops being public is taken back down.
#
# Core's bundled chat integration only posts "new topic/reply" notices into
# one channel; it has no thread per topic, no edits or deletions, and no way
# to take content back down, which a mirror needs.

module ::DiscourseDiscordMirror
  LOG_TAG = "[jtech-tools discord-mirror]"

  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.discord_mirror_enabled
  end

  def self.configured?
    enabled? && SiteSetting.discord_mirror_bot_token.present? &&
      SiteSetting.discord_mirror_guild_id.to_s.strip.present?
  end

  def self.sync_topic(topic_id)
    return unless configured?
    return if topic_id.blank?
    Jobs.enqueue_in(5.seconds, :discord_mirror_sync_topic, topic_id: topic_id)
  end
end

require_relative "../lib/discourse_discord_mirror/api"
require_relative "../lib/discourse_discord_mirror/models"
require_relative "../lib/discourse_discord_mirror/visibility"
require_relative "../lib/discourse_discord_mirror/renderer"
require_relative "../lib/discourse_discord_mirror/structure"
require_relative "../lib/discourse_discord_mirror/topic_sync"
require_relative "../lib/discourse_discord_mirror/backfill"

after_initialize do
  mirror_topic = ->(topic) do
    next unless DiscourseDiscordMirror.configured?
    next if topic.nil? || topic.archetype != Archetype.default
    DiscourseDiscordMirror.sync_topic(topic.id)
  end

  %i[post_created post_edited post_destroyed post_recovered].each do |event|
    on(event) do |post, *_args|
      mirror_topic.call(post&.topic || Topic.with_deleted.find_by(id: post&.topic_id))
    end
  end

  %i[topic_destroyed topic_recovered topic_closed].each do |event|
    on(event) { |topic, *_args| mirror_topic.call(topic) }
  end

  on(:post_moved) do |post, original_topic_id, *_args|
    next unless DiscourseDiscordMirror.configured?
    DiscourseDiscordMirror.sync_topic(post&.topic_id)
    DiscourseDiscordMirror.sync_topic(original_topic_id)
  end

  %i[category_created category_updated category_destroyed].each do |event|
    on(event) do |_category|
      next unless DiscourseDiscordMirror.configured?
      Jobs.enqueue_in(10.seconds, :discord_mirror_sync_structure)
    end
  end

  # The mirror shows names and avatars, so an anonymized account's messages
  # are taken down and sent again under the new name (a webhook message's
  # author can't be edited).
  on(:user_anonymized) do |args|
    next unless DiscourseDiscordMirror.configured?
    user = args[:user]
    next if user.nil?
    topic_ids =
      DiscourseDiscordMirror::MirrorMessage.where(user_id: user.id).distinct.pluck(:topic_id)
    DiscourseDiscordMirror::MirrorMessage.where(user_id: user.id).update_all(
      content_digest: DiscourseDiscordMirror::TopicSync::RESEND,
    )
    topic_ids.each { |id| DiscourseDiscordMirror.sync_topic(id) }
  end

  on(:site_setting_changed) do |name, _old, _new|
    unless %i[
             discord_mirror_enabled
             discord_mirror_bot_token
             discord_mirror_guild_id
             discord_mirror_excluded_categories
             discord_mirror_backfill_days
           ].include?(name)
      next
    end
    next unless DiscourseDiscordMirror.configured?

    Jobs.enqueue(:discord_mirror_sync_structure)
    if name == :discord_mirror_backfill_days || name == :discord_mirror_enabled
      DiscourseDiscordMirror::Backfill.restart
      Jobs.enqueue_in(1.minute, :discord_mirror_backfill)
    end
  end
end
