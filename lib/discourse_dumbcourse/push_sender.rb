# frozen_string_literal: true

require "json"

module DiscourseDumbcourse
  class PushSender
    TYPE_PREFERENCE_MAP = {
      replied: :direct_replies,
      mentioned: :mentions,
      quoted: :quotes,
      edited: :watching,
      liked: :likes,
      liked_consolidated: :likes,
      reaction: :likes,
      private_message: :messages,
      invited_to_private_message: :messages,
      group_message_summary: :messages,
      posted: :watching,
      watching_first_post: :watching,
      watching_category_or_tag: :watching,
      topic_reminder: :watching,
      chat_message: :messages,
      chat_mention: :mentions,
      chat_group_mention: :mentions,
      chat_quoted: :quotes,
    }.freeze

    # A user's registered devices: { device_id => { "topic" => …, … } }.
    def self.devices(user_id)
      PluginStore.get("dumbcourse", "push_devices_#{user_id}") || {}
    end

    def self.store_devices(user_id, devices)
      PluginStore.set("dumbcourse", "push_devices_#{user_id}", devices)
    end

    def self.send_to_user(user_id, title:, message:, click_url: nil, priority: "default")
      unless SiteSetting.dumbcourse_push_enabled
        Rails.logger.info("[Dumbcourse Push] Push disabled, skipping for user #{user_id}")
        return
      end

      devices = self.devices(user_id)
      if devices.empty?
        Rails.logger.info("[Dumbcourse Push] No devices for user #{user_id}")
        return
      end

      Rails.logger.info("[Dumbcourse Push] Sending to user #{user_id}: #{devices.size} device(s)")
      devices.each do |device_id, device_info|
        topic = device_info["topic"]
        next if topic.blank?

        Rails.logger.info("[Dumbcourse Push] -> device=#{device_id} topic=#{topic}")
        send_notification(
          topic: topic,
          title: title,
          message: message,
          click_url: click_url,
          priority: priority,
        )
      end
    end

    def self.send_notification(
      topic:,
      title:,
      message:,
      click_url: nil,
      priority: "default",
      server: nil
    )
      channel = "dumbcourse_push:#{topic}"

      payload = {
        topic: topic,
        title: title.to_s[0..99],
        message: message.to_s[0..4095],
        priority: map_priority(priority),
      }

      payload[:click] = click_url if click_url.present?

      begin
        subscribers = Discourse.redis.publish(channel, payload.to_json)
        Rails.logger.info("[Dumbcourse Push] Published to #{topic}: #{subscribers} subscriber(s)")
      rescue StandardError => e
        Rails.logger.error("[Dumbcourse Push] Error publishing to #{topic}: #{e.message}")
      end
    end

    def self.map_priority(priority)
      case priority.to_s
      when "urgent", "high"
        5
      when "low"
        2
      when "min"
        1
      else
        3 # default
      end
    end

    # Check if user wants this notification type
    def self.user_wants_notification?(user_id, type)
      prefs = PluginStore.get("dumbcourse", "push_prefs_#{user_id}")
      return type != :likes if prefs.nil? # Default: send all except likes
      prefs[type.to_s] != false && prefs[type.to_sym] != false
    end

    def self.user_wants_notification_for_type?(user_id, type)
      return true if type.nil?

      pref_key = TYPE_PREFERENCE_MAP[type]
      return true if pref_key.nil?

      user_wants_notification?(user_id, pref_key)
    end

    def self.notify_notification(notification)
      return if notification.blank?

      type = Notification.types.key(notification.notification_type)
      return unless user_wants_notification_for_type?(notification.user_id, type)

      data = notification.data_hash
      username =
        data[:display_username] || data[:username] || data[:mentioned_by_username] ||
          data[:invited_by_username] || data[:original_username]
      topic_title = data[:topic_title] || notification.topic&.title
      message = data[:excerpt] || data[:message] || topic_title || "You have a new notification."

      title =
        case type
        when :mentioned
          "#{username || "Someone"} mentioned you"
        when :replied
          "#{username || "Someone"} replied to you"
        when :quoted
          "#{username || "Someone"} quoted you"
        when :edited
          "#{username || "Someone"} edited a post"
        when :liked
          "#{username || "Someone"} liked your post"
        when :private_message
          "Private message from #{username || "someone"}"
        when :invited_to_private_message
          "#{username || "Someone"} invited you to a private message"
        when :invitee_accepted
          "#{username || "Someone"} accepted your invitation"
        when :posted
          "New post in #{topic_title || "a topic"}"
        when :moved_post
          "#{username || "Someone"} moved a post"
        when :linked
          "#{username || "Someone"} linked to your post"
        when :granted_badge
          "Badge granted: #{data[:badge_name] || "New badge"}"
        when :invited_to_topic
          "#{username || "Someone"} invited you to a topic"
        when :custom
          data[:title] || "New notification"
        when :group_mentioned
          group = data[:group_name] || "your group"
          "#{username || "Someone"} mentioned @#{group}"
        when :group_message_summary
          "New group messages"
        when :watching_first_post
          "New topic in #{data[:category_name] || "watched category"}"
        when :topic_reminder
          "Topic reminder"
        when :liked_consolidated
          "New likes"
        when :post_approved
          "Post approved"
        when :code_review_commit_approved
          "Code review approved"
        when :membership_request_accepted
          "Membership request accepted"
        when :membership_request_consolidated
          "Membership requests update"
        when :bookmark_reminder
          "Bookmark reminder"
        when :reaction
          "#{username || "Someone"} reacted to your post"
        when :votes_released
          "Votes released"
        when :event_reminder
          "Event reminder"
        when :event_invitation
          "Event invitation"
        when :chat_mention
          "#{username || "Someone"} mentioned you in chat"
        when :chat_message
          "New chat message"
        when :chat_invitation
          "Chat invitation"
        when :chat_group_mention
          "#{username || "Someone"} mentioned your group in chat"
        when :chat_quoted
          "#{username || "Someone"} quoted you in chat"
        when :assigned
          "#{username || "Someone"} assigned you"
        when :question_answer_user_commented
          "#{username || "Someone"} commented on your answer"
        when :watching_category_or_tag
          "New activity in watched category/tag"
        when :new_features
          "New features available"
        when :admin_problems
          "Admin problems detected"
        when :linked_consolidated
          "New links to your posts"
        when :chat_watched_thread
          "New chat thread activity"
        when :upcoming_change_available
          "Upcoming change available"
        when :upcoming_change_automatically_promoted
          "Upcoming change promoted"
        when :following
          "New activity from someone you follow"
        when :following_created_topic
          "New topic from someone you follow"
        when :following_replied
          "New reply from someone you follow"
        when :circles_activity
          "New circles activity"
        else
          "New notification"
        end

      click_url =
        if notification.url.present?
          "#{Discourse.base_url}#{DiscourseDumbcourse.base_path_with_slash}#{notification.url}"
        else
          "#{Discourse.base_url}#{DiscourseDumbcourse.base_path_with_slash}/notifications"
        end

      priority =
        if notification.high_priority?
          "high"
        elsif %i[liked liked_consolidated reaction].include?(type)
          "low"
        else
          "default"
        end

      send_to_user(
        notification.user_id,
        title: title,
        message: message,
        click_url: click_url,
        priority: priority,
      )
    end
  end
end
