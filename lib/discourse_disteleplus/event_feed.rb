# frozen_string_literal: true

module DiscourseDisteleplus
  # Automatic system messages in the conversation when forum events happen —
  # the staff room narrates the forum. Which events post is the
  # disteleplus_event_messages multi-select. Messages come from the system
  # user, skip bell notifications, and skip the Telegram bridge: the
  # Telegram side already has its own reports pipeline with action buttons,
  # and mirroring both would double every event.
  #
  # Review-queue items are deliberately NOT here: staff already receive a
  # bell notification per review item, so a chat line repeating it was the
  # same report twice. Reports live in the review queue and — with action
  # buttons — in the Telegram reports topic.
  module EventFeed
    def self.on?(event)
      DiscourseDisteleplus.enabled? &&
        SiteSetting.disteleplus_event_messages_map.include?(event.to_s)
    end

    def self.post!(raw)
      MessageService.new(actor: Discourse.system_user).create!(
        raw: raw,
        bridge: false,
        notify: false,
      )
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} event feed failed: #{e.message}")
    end

    def self.topic_created(topic)
      return if topic.blank? || !topic.regular? || !topic.visible
      # System-authored topics (the polls holder, warnings) are plumbing.
      return if topic.user_id.to_i <= 0
      post!("📰 New topic by @#{topic.user.username}: [#{topic.title}](#{topic.url})")
    end

    def self.user_first_logged_in(user)
      post!("👋 @#{user.username} logged in for the first time")
    end

    def self.user_suspended(payload)
      user = payload[:user]
      return if user.blank?
      until_text = payload[:suspended_till]&.to_date&.to_s || "forever"
      reason = payload[:reason].presence
      post!("⛔ @#{user.username} was suspended until #{until_text}#{" — #{reason}" if reason}")
    end

    def self.user_silenced(payload)
      user = payload[:user]
      return if user.blank?
      until_text = payload[:silenced_till]&.to_date&.to_s || "forever"
      reason = payload[:reason].presence
      post!("🔇 @#{user.username} was silenced until #{until_text}#{" — #{reason}" if reason}")
    end
  end
end
