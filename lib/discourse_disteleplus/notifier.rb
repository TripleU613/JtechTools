# frozen_string_literal: true

module DiscourseDisteleplus
  module Notifier
    PATH = "/disteleplus"

    # Deep link straight to the message; the conversation reads the #m<id>
    # hash on open and scrolls/highlights (fetching a window around it when
    # it is no longer in the freshly-loaded tail).
    def self.message_url(message)
      "#{PATH}#m#{message.id}"
    end

    # Notifications are for @mentions only. Every message already bumps the
    # unread badge; a notification per message was noise.
    def self.notify(message, actor:)
      return unless SiteSetting.disteleplus_force_channel_notifications

      mentioned_ids = mentioned_user_ids(message)
      return if mentioned_ids.empty?

      bot_id = DiscourseDisteleplus.bot_user&.id
      recipients =
        Access.allowed_users.where(id: mentioned_ids).where.not(id: [actor&.id, bot_id].compact)
      preview = excerpt(message)
      sender = display_name(message)
      recipients.find_each do |recipient|
        notification =
          Notification.create!(
            notification_type: Notification.types[:custom],
            user_id: recipient.id,
            high_priority: true,
            data: {
              # The bell row shows the message itself, not just "mentioned
              # you" — and the toast card reuses excerpt + avatar directly.
              message:
                I18n.t(
                  "disteleplus.notification_with_preview",
                  username: sender,
                  excerpt: preview,
                  default: "#{sender} mentioned you: #{preview}",
                ),
              title: I18n.t("disteleplus.title"),
              url: message_url(message),
              username: actor&.username,
              display_username: actor&.username,
              avatar_template: actor&.avatar_template,
              excerpt: preview,
              disteleplus_message_id: message.id,
              disteleplus: true,
            }.to_json,
          )
        enqueue_push(recipient, message, notification)
      end
    rescue StandardError => e
      raise if Rails.env.test?
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} notification fan-out failed: #{e.message}",
      )
    end

    # User ids addressed by @user and @group mentions in the cooked message.
    def self.mentioned_user_ids(message)
      return [] if message.cooked.blank?

      doc = Nokogiri::HTML5.fragment(message.cooked)
      # The anchor text can be a display name (prioritize_username_in_ux off);
      # the href always carries the username / group name. Bare PrettyText
      # cooking can also emit href-less <span class="mention"> — fall back to
      # the element text so those mentions still notify.
      names =
        doc
          .css("a.mention, span.mention")
          .filter_map do |el|
            el["href"].to_s[%r{/u/([^/?#]+)}, 1]&.downcase ||
              el.text.to_s.delete_prefix("@").downcase.presence
          end
      group_names =
        doc
          .css("a.mention-group, span.mention-group")
          .filter_map do |el|
            el["href"].to_s[%r{/groups/([^/?#]+)}, 1]&.downcase ||
              el.text.to_s.delete_prefix("@").downcase.presence
          end
      ids = names.empty? ? [] : User.where(username_lower: names).pluck(:id)
      if group_names.any?
        group_ids = Group.where("LOWER(name) IN (?)", group_names).pluck(:id)
        ids |= GroupUser.where(group_id: group_ids).pluck(:user_id) if group_ids.any?
      end
      ids.uniq
    end

    def self.mark_read(user, through_id)
      # post_number is a 4-byte column; the message id lives in the JSON data.
      updated =
        Notification
          .where(user_id: user.id, notification_type: Notification.types[:custom], read: false)
          .where("data LIKE ?", '%"disteleplus":true%')
          .where("(data::json->>'disteleplus_message_id')::bigint <= ?", through_id.to_i)
          .update_all(read: true)
      # Every read advances this; most of them have nothing left to clear.
      user.publish_notifications_state if updated > 0
    end

    # Reuses core PostAlerter.push_notification so we inherit its gate stack:
    # subscription check, do-not-disturb, plugin push filters, the delivery
    # time window and the :push_notification event.
    def self.enqueue_push(user, message, notification)
      return unless defined?(::PostAlerter)

      ::PostAlerter.push_notification(
        user,
        {
          notification_type: notification.notification_type,
          topic_title: I18n.t("disteleplus.title"),
          excerpt: excerpt(message),
          username: display_name(message),
          post_url: message_url(message),
        },
      )
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} push enqueue failed: #{e.message}")
    end

    def self.display_name(message)
      message.external_sender_name.presence || message.user&.username || "Telegram"
    end

    def self.excerpt(message)
      return I18n.t("disteleplus.upload_only") if message.raw.blank?

      Post.excerpt(
        message.cooked,
        180,
        text_entities: true,
        strip_links: true,
        remap_emoji: true,
        plain_hashtags: true,
      )
    end
  end
end
