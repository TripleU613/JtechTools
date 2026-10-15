# frozen_string_literal: true

module DiscourseDisteleplus
  # Telegram-side setup wizard. Telegram messages always identify their chat
  # and thread numerically, so an admin can bind the right destinations by
  # issuing a command in context instead of copying IDs into Discourse.
  class SetupCommandHandler
    COMMAND =
      %r{
      \A/disteleplus_
      (setup|help|status|bind_general|bind_uploads|create_uploads|sync_notifications|bind_reports)
      (?:@\w+)?
      (?:\s+(.+))?
      \z
    }ix
    ADMIN_STATUSES = %w[creator administrator].freeze
    DEFAULT_UPLOAD_TOPIC_NAME = "Uploads"

    def initialize(message, api: TelegramApi.new)
      @message = message
      @api = api
    end

    # Returns true whenever the message is a Disteleplus command—even on
    # failure—so setup chatter can never cross into the native conversation.
    def process?
      match = @message["text"].to_s.strip.match(COMMAND)
      return false if match.nil?

      unless SiteSetting.disteleplus_setup_commands_enabled
        reply("Setup commands are disabled in Discourse admin settings.")
        return true
      end
      unless group_message?
        reply("Run this command inside the #{SiteSetting.title} Telegram group.")
        return true
      end
      unless telegram_admin?
        reply("Only a Telegram group administrator can configure Disteleplus.")
        return true
      end

      command = match[1].downcase

      # Reports may live in a different (private, staff-only) group than the
      # bridged conversation, so the "already bound elsewhere" guard does not
      # apply — instead the sender must prove Discourse-admin identity via an
      # explicit telegram_id mapping row.
      if command == "bind_reports"
        handle_bind_reports(normalized_topic_name(match[2]))
        return true
      end

      unless authorized_group?
        reply(
          "Disteleplus is already bound to another group. " \
            "Clear the Telegram chat ID in Discourse admin before moving it.",
        )
        return true
      end

      topic_name = normalized_topic_name(match[2])
      send("handle_#{command}", topic_name)
      true
    rescue TelegramApi::RateLimited
      raise
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} setup command failed: #{e.message}")
      reply("Setup failed. Check Discourse <code>/logs</code> for details.")
      true
    end

    private

    def handle_help(_topic_name)
      reply(<<~HTML.strip)
        <b>Disteleplus setup</b>

        In General:
        <code>/disteleplus_bind_general</code>

        Inside an existing Uploads topic:
        <code>/disteleplus_bind_uploads</code>

        Or create and bind it automatically from General:
        <code>/disteleplus_create_uploads Uploads</code>

        Inside the topic (or group) that should receive moderation reports:
        <code>/disteleplus_bind_reports</code>

        Check the saved destinations, notifications and voice notes:
        <code>/disteleplus_status</code>

        Re-enrol every eligible Discourse member for notifications now:
        <code>/disteleplus_sync_notifications</code>

        Binding does not start history automatically.
        Measure and start the backfill from Discourse admin settings.
      HTML
    end

    alias handle_setup handle_help

    def handle_status(_topic_name)
      configured_chat = SiteSetting.disteleplus_telegram_chat_id.to_s.strip
      upload_name =
        SiteSetting.disteleplus_forum_upload_topic_name.presence || DEFAULT_UPLOAD_TOPIC_NAME
      upload_id = SiteSetting.disteleplus_forum_upload_topic_id.to_i
      group_state = configured_chat == chat_id.to_s ? "this group" : "another/unbound group"
      upload_state =
        if DiscourseDisteleplus.general_topic?(upload_id) && upload_id.positive?
          "⚠️ topic id 1 is General — archive sends fail; run " \
            "<code>/disteleplus_create_uploads Uploads</code>"
        elsif upload_id.positive?
          "#{escape(upload_name)} (<code>#{upload_id}</code>)"
        else
          "not bound"
        end
      mirror_state = SiteSetting.disteleplus_forum_uploads_enabled ? "enabled" : "disabled"
      reply(<<~HTML.strip)
        <b>Disteleplus status</b>
        Group: #{escape(chat_title)} — #{group_state}
        Native conversation: /disteleplus
        Telegram conversation: #{SiteSetting.disteleplus_chat_topic_id.to_i.positive? ? "topic #{SiteSetting.disteleplus_chat_topic_id}" : "General"}
        Upload archive: #{upload_state}
        Live upload mirror: #{mirror_state}
        Moderation reports: #{reports_state}
        Report buttons: #{callback_delivery_state}
        Notifications: #{escape(ChannelNotifications.status_summary)}
        Voice notes: #{escape(VoiceNotes.status_summary)}
      HTML
    end

    def handle_sync_notifications(_topic_name)
      unless SiteSetting.disteleplus_force_channel_notifications
        reply(
          "Forced notifications are off. Enable " \
            "<code>disteleplus_force_channel_notifications</code> in Discourse admin first.",
        )
        return
      end
      Jobs.enqueue(:disteleplus_sync_channel_notifications)
      reply(<<~HTML.strip)
        🔔 <b>Notification sync queued</b>
        Every eligible Discourse member is being enrolled in the native conversation
        at notification level <i>always</i>. Run <code>/disteleplus_status</code>
        in a minute to see the count.
      HTML
    end

    def handle_bind_general(_topic_name)
      if thread_id.positive?
        reply(
          "Send <code>/disteleplus_bind_general</code> in the group's General " \
            "conversation, not inside a topic.",
        )
        return
      end

      bind_group!
      SiteSetting.disteleplus_chat_topic_id = 0
      reply(<<~HTML.strip)
        ✅ <b>General bound</b>
        Group: #{escape(chat_title)}
        The native Disteleplus conversation will use General.

        Next, enter the Uploads topic and send:
        <code>/disteleplus_bind_uploads</code>
      HTML
    end

    def handle_bind_uploads(topic_name)
      unless thread_id.positive?
        reply(
          "Run <code>/disteleplus_bind_uploads</code> inside the Telegram topic " \
            "that should receive uploads.",
        )
        return
      end
      if thread_id == SiteSetting.disteleplus_chat_topic_id.to_i
        reply("The upload archive and Disteleplus conversation cannot use the same Telegram topic.")
        return
      end

      bind_group!
      SiteSetting.disteleplus_forum_upload_topic_id = thread_id
      SiteSetting.disteleplus_forum_upload_topic_name = topic_name
      reply(<<~HTML.strip)
        ✅ <b>Upload topic bound</b>
        Topic: #{escape(topic_name)}
        Group: #{escape(chat_title)}

        New and historical forum files will use this topic after the mirror
        is enabled in Discourse.
        Run <code>/disteleplus_status</code> to verify.
      HTML
    end

    # Binds THIS chat (and, when sent inside a Telegram forum topic, this
    # topic) as the moderation-reports destination and enables the feature.
    # Gated on an explicit telegram_id → Discourse-admin mapping: report
    # traffic includes flagged content and the buttons perform real
    # moderation, so a mere Telegram group admin is not enough.
    def handle_bind_reports(_topic_name)
      admin = UserMatcher.privileged_match(@message["from"])
      unless admin&.admin?
        reply(
          "Binding reports requires a Discourse admin. Add your Telegram " \
            "<b>numeric ID</b> to a row of <code>disteleplus_user_map</code> " \
            "pointing at your admin account, then retry.",
        )
        return
      end
      if thread_id == SiteSetting.disteleplus_chat_topic_id.to_i &&
           chat_id.to_s == SiteSetting.disteleplus_telegram_chat_id.to_s.strip
        reply("Reports cannot share the Telegram topic used by the bridged conversation.")
        return
      end

      SiteSetting.set_and_log(:disteleplus_reports_chat_id, chat_id.to_s, admin)
      SiteSetting.set_and_log(:disteleplus_reports_topic_id, [thread_id, 0].max, admin)
      SiteSetting.set_and_log(:disteleplus_reports_enabled, true, admin)
      # Re-register so Telegram starts delivering callback_query updates.
      Jobs.enqueue(:disteleplus_register_webhook)
      reply(<<~HTML.strip)
        ✅ <b>Reports bound</b>
        Group: #{escape(chat_title)}
        Topic: #{thread_id.positive? ? "<code>#{thread_id}</code>" : "General"}

        New flags, queued posts and user reviews will appear here with
        Approve / Deny / More buttons. Only staff mapped by Telegram numeric ID
        in <code>disteleplus_user_map</code> can use them.
      HTML
    end

    def handle_create_uploads(topic_name)
      if thread_id.positive?
        reply(
          "Create the archive from General, or use " \
            "<code>/disteleplus_bind_uploads</code> in an existing topic.",
        )
        return
      end
      if SiteSetting.disteleplus_forum_upload_topic_id.to_i.positive?
        reply(
          "An upload topic is already bound. Run <code>/disteleplus_status</code>, " \
            "or bind a different existing topic with <code>/disteleplus_bind_uploads</code>.",
        )
        return
      end

      result = @api.call("createForumTopic", chat_id: chat_id, name: topic_name)
      unless result.ok
        reply(
          "Could not create the topic: #{escape(result.description)}. " \
            "Give the bot permission to manage topics, or bind an existing topic.",
        )
        return
      end

      created_thread_id = result.result&.dig("message_thread_id").to_i
      raise "createForumTopic returned no message_thread_id" unless created_thread_id.positive?

      bind_group!
      SiteSetting.disteleplus_forum_upload_topic_id = created_thread_id
      SiteSetting.disteleplus_forum_upload_topic_name = topic_name
      reply(<<~HTML.strip)
        ✅ <b>Upload topic created and bound</b>
        Topic: #{escape(topic_name)}

        Enable the live mirror, measure the archive, and start history from
        Discourse admin settings.
      HTML
    end

    def reports_state
      return "disabled" unless SiteSetting.disteleplus_reports_enabled
      target_chat = Reports.chat_id
      topic = SiteSetting.disteleplus_reports_topic_id.to_i
      where =
        target_chat == chat_id.to_s ? "this group" : "chat <code>#{escape(target_chat)}</code>"
      "enabled — #{where}, #{topic.positive? ? "topic <code>#{topic}</code>" : "General"}"
    end

    # Whether Telegram will deliver button presses at all: the webhook's
    # stored allowed_updates must list callback_query (an empty list means
    # every update type). This is THE diagnostic for report buttons that
    # spin forever.
    def callback_delivery_state
      info = @api.call("getWebhookInfo")
      return "unknown (getWebhookInfo failed)" unless info.ok
      allowed = info.result&.dig("allowed_updates")
      if allowed.blank? || allowed.include?("callback_query")
        "delivering"
      else
        "⚠️ NOT delivered — press “Register Telegram webhook” in Discourse admin"
      end
    end

    def telegram_admin?
      user_id = @message.dig("from", "id")
      return false if user_id.blank?

      result = @api.call("getChatMember", chat_id: chat_id, user_id: user_id)
      result.ok && ADMIN_STATUSES.include?(result.result&.dig("status"))
    end

    def authorized_group?
      configured = SiteSetting.disteleplus_telegram_chat_id.to_s.strip
      configured.blank? || configured == chat_id.to_s
    end

    def bind_group!
      previous_chat = SiteSetting.disteleplus_telegram_chat_id.to_s.strip
      if previous_chat.present? && previous_chat != chat_id.to_s
        SiteSetting.disteleplus_forum_upload_topic_id = 0
        SiteSetting.disteleplus_forum_upload_topic_name = DEFAULT_UPLOAD_TOPIC_NAME
      end
      SiteSetting.disteleplus_telegram_chat_id = chat_id.to_s
    end

    def reply(text)
      payload = { chat_id: chat_id, text: text, parse_mode: "HTML" }
      payload[:message_thread_id] = thread_id if thread_id.positive?
      payload[:reply_to_message_id] = @message["message_id"] if @message["message_id"]
      result = @api.call("sendMessage", payload)
      unless result.ok
        Rails.logger.warn(
          "#{DiscourseDisteleplus::LOG_TAG} setup reply failed: #{result.description}",
        )
      end
      result
    end

    def normalized_topic_name(argument)
      argument.to_s.squish.presence&.first(128) || DEFAULT_UPLOAD_TOPIC_NAME
    end

    def group_message?
      %w[group supergroup].include?(@message.dig("chat", "type"))
    end

    def chat_id
      @message.dig("chat", "id")
    end

    def chat_title
      @message.dig("chat", "title").presence || chat_id.to_s
    end

    def thread_id
      @message["message_thread_id"].to_i
    end

    def escape(value)
      Formatter.escape_html(value.to_s)
    end
  end
end
