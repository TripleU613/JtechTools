# frozen_string_literal: true

# Jtech sub-plugin: Disteleplus — Telegram ⇄ native Discourse conversation.
#
# Disteleplus owns its messages, uploads, reactions, unread state, API,
# realtime channel, notifications and UI. The official Discourse Chat plugin
# is not required. An isolated optional importer can read a legacy Chat
# channel during migration, but normal operation never touches Chat models,
# services, routes, memberships, events, or frontend APIs.

register_asset "stylesheets/disteleplus.scss"
register_asset "stylesheets/disteleplus-native.scss"

# Icons drawn by the header shortcut, conversation, context menu, composer and
# voice recorder. Discourse ships only a subset of FontAwesome in its sprite;
# an unregistered icon renders as an empty <svg>.
%w[
  angles-up
  arrow-down
  bell
  chart-bar
  chart-pie
  chart-simple
  check
  check-double
  circle-check
  circle-info
  comments
  headphones
  discourse-compress
  discourse-expand
  copy
  download
  ellipsis
  far-circle
  lock
  unlock
  face-smile
  file
  link
  magnifying-glass
  microphone
  minus
  paperclip
  paper-plane
  pencil
  play
  plus
  quote-right
  reply
  rotate
  shuffle
  spinner
  stop
  trash-can
  upload
  xmark
].each { |name| register_svg_icon(name) }

module ::DiscourseDisteleplus
  # Module switch AND the bundle master (jtech_enabled). Discourse's own
  # plugin gate stops event hooks, serializers and assets when the master is
  # off, but not the core-class patches or scheduled jobs, so every read of
  # this module's switch goes through here.
  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.disteleplus_enabled
  end

  LOG_TAG = "[jtech-tools disteleplus]"
  GENERAL_TOPIC_IDS = [0, 1].freeze
  # Members of this group are excluded from the /about page's "Our admins" /
  # "Our moderators" lists via core's about_page_hidden_groups setting, so the
  # bridge account stays a silent worker even when an admin grants it
  # moderator rights.
  HIDDEN_BOTS_GROUP = "jtech_bridge_bots"
  # Bump whenever DisteleplusRegisterWebhook#allowed_updates gains an update
  # type — after_initialize then re-registers the webhook once per site.
  ALLOWED_UPDATES_REV = 2

  def self.bot_user
    username = SiteSetting.disteleplus_bridge_bot_username.to_s.strip
    return nil if username.blank?
    user = User.find_by_username(username) || create_bot_user!(username)
    ensure_bot_hidden!(user)
    user
  end

  def self.create_bot_user!(username)
    user =
      User.create!(
        username: username,
        name: "Telegram Bridge",
        email: "no-reply.disteleplus@#{Discourse.current_hostname}",
        password: SecureRandom.hex(32),
        active: true,
        approved: true,
        trust_level: TrustLevel[4],
      )
    user.activate
    user
  rescue StandardError => e
    Rails.logger.warn("#{LOG_TAG} bot user create failed: #{e.class}: #{e.message}")
    nil
  end

  # Idempotent and memoized per process: puts the bot in a hidden group and
  # registers that group in about_page_hidden_groups so the bot never shows
  # up under "meet our team" even as a moderator/admin.
  def self.ensure_bot_hidden!(user)
    return if user.nil?
    @hidden_bot_ids ||= {}
    return if @hidden_bot_ids[user.id]
    return unless SiteSetting.respond_to?(:about_page_hidden_groups)

    group =
      Group.find_by(name: HIDDEN_BOTS_GROUP) ||
        Group.create!(
          name: HIDDEN_BOTS_GROUP,
          full_name: "JTech bridge bots",
          visibility_level: Group.visibility_levels[:staff],
          members_visibility_level: Group.visibility_levels[:staff],
          public_admission: false,
          allow_membership_requests: false,
        )
    group.add(user) unless GroupUser.exists?(group_id: group.id, user_id: user.id)

    hidden = SiteSetting.about_page_hidden_groups.to_s.split("|")
    if hidden.exclude?(group.id.to_s)
      SiteSetting.set_and_log(
        :about_page_hidden_groups,
        (hidden + [group.id.to_s]).join("|"),
        Discourse.system_user,
      )
    end
    @hidden_bot_ids[user.id] = true
  rescue StandardError => e
    Rails.logger.warn("#{LOG_TAG} could not hide bot from /about: #{e.class}: #{e.message}")
  end

  def self.telegram_thread_id(value)
    id = value.to_i
    GENERAL_TOPIC_IDS.include?(id) ? nil : id
  end

  def self.general_topic?(value)
    GENERAL_TOPIC_IDS.include?(value.to_i)
  end
end

require_relative "../lib/discourse_disteleplus/emoji_map"
require_relative "../lib/discourse_disteleplus/formatter"
require_relative "../lib/discourse_disteleplus/telegram_api"
require_relative "../lib/discourse_disteleplus/user_matcher"
require_relative "../lib/discourse_disteleplus/access"
require_relative "../lib/discourse_disteleplus/polls"
require_relative "../lib/discourse_disteleplus/event_feed"
require_relative "../lib/discourse_disteleplus/message_serializer"
require_relative "../lib/discourse_disteleplus/publisher"
require_relative "../lib/discourse_disteleplus/notifier"
require_relative "../lib/discourse_disteleplus/message_service"
require_relative "../lib/discourse_disteleplus/deletion_sync"
require_relative "../lib/discourse_disteleplus/setup_command_handler"
require_relative "../lib/discourse_disteleplus/update_processor"
require_relative "../lib/discourse_disteleplus/forum_upload_policy"
require_relative "../lib/discourse_disteleplus/forum_upload_formatter"
require_relative "../lib/discourse_disteleplus/telegram_upload_sender"
require_relative "../lib/discourse_disteleplus/forum_upload_metrics"
require_relative "../lib/discourse_disteleplus/channel_notifications"
require_relative "../lib/discourse_disteleplus/voice_notes"
require_relative "../lib/discourse_disteleplus/legacy_chat_importer"
require_relative "../lib/discourse_disteleplus/health"
require_relative "../lib/discourse_disteleplus/forum_post_notifier"
require_relative "../lib/discourse_disteleplus/reports"

after_initialize do
  # Serializer classes only exist once the app has booted.
  add_to_serializer(:current_user, :can_access_disteleplus) do
    ::DiscourseDisteleplus::Access.allowed?(object)
  end

  on(:site_setting_changed) do |name, _old_val, new_val|
    case name.to_s
    when "disteleplus_register_webhook_now"
      if new_val == true
        if DiscourseDisteleplus.enabled?
          if SiteSetting.disteleplus_webhook_secret.blank?
            SiteSetting.disteleplus_webhook_secret = SecureRandom.hex(32)
          end
          Jobs.enqueue(:disteleplus_register_webhook)
        end
        SiteSetting.disteleplus_register_webhook_now = false
      end
    when "disteleplus_forum_upload_measure_now"
      if new_val == true
        if DiscourseDisteleplus.enabled? && SiteSetting.disteleplus_forum_uploads_enabled
          Jobs.enqueue(:disteleplus_measure_forum_uploads)
        end
        SiteSetting.disteleplus_forum_upload_measure_now = false
      end
    when "disteleplus_forum_upload_backfill_now"
      if new_val == true
        if DiscourseDisteleplus.enabled? && SiteSetting.disteleplus_forum_uploads_enabled
          Jobs.enqueue(:disteleplus_backfill_forum_uploads, after_reference_id: 0)
        end
        SiteSetting.disteleplus_forum_upload_backfill_now = false
      end
    when "disteleplus_send_test_message_now"
      if new_val == true
        Jobs.enqueue(:disteleplus_send_test_message) if DiscourseDisteleplus.enabled?
        SiteSetting.disteleplus_send_test_message_now = false
      end
    when "disteleplus_setup_commands_enabled"
      Jobs.enqueue(:disteleplus_register_webhook) if DiscourseDisteleplus.enabled?
    when "disteleplus_notification_sync_now"
      if new_val == true
        Jobs.enqueue(:disteleplus_sync_channel_notifications) if DiscourseDisteleplus.enabled?
        SiteSetting.disteleplus_notification_sync_now = false
      end
    when "disteleplus_force_channel_notifications", "disteleplus_allowed_groups",
         "disteleplus_enabled"
      if DiscourseDisteleplus::ChannelNotifications.active?
        Jobs.enqueue(:disteleplus_sync_channel_notifications)
      end
      if DiscourseDisteleplus::VoiceNotes.enabled?
        DiscourseDisteleplus::VoiceNotes.ensure_extensions_authorized!
      end
    when "disteleplus_voice_notes_enabled"
      if new_val == true && DiscourseDisteleplus.enabled?
        DiscourseDisteleplus::VoiceNotes.ensure_extensions_authorized!
      end
    when "disteleplus_reports_enabled", "disteleplus_reports_chat_id"
      # Refresh the webhook registration and command menu, and make sure the
      # reports topic exists in the (possibly new) reports chat.
      if DiscourseDisteleplus.enabled?
        Jobs.enqueue(:disteleplus_register_webhook)
        Jobs.enqueue(:disteleplus_ensure_reports_topic) if SiteSetting.disteleplus_reports_enabled
      end
    end
  end

  # Self-migrating reports topic: a deploy that enables (or already has)
  # reports without a stored topic id creates the "Reports" forum topic on
  # its own — nobody has to bind anything by hand, and nothing is ever
  # posted into General.
  begin
    if DiscourseDisteleplus.enabled? && SiteSetting.disteleplus_reports_enabled &&
         SiteSetting.disteleplus_bot_token.present? &&
         DiscourseDisteleplus.telegram_thread_id(SiteSetting.disteleplus_reports_topic_id).nil?
      Jobs.enqueue(:disteleplus_ensure_reports_topic)
    end
  rescue StandardError => e
    Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} reports topic check failed: #{e.message}")
  end

  # One-time self-heal per allowed_updates revision: Telegram keeps the
  # allowed_updates list from the LAST setWebhook call, so an already-bridged
  # install upgraded to a version that needs a new update type (callback_query
  # for report buttons) would never receive it until an admin pressed the
  # register button. Re-register automatically, once.
  begin
    if DiscourseDisteleplus.enabled? && SiteSetting.disteleplus_bot_token.present? &&
         SiteSetting.disteleplus_webhook_secret.present? &&
         PluginStore.get("disteleplus", "allowed_updates_rev").to_i <
           DiscourseDisteleplus::ALLOWED_UPDATES_REV
      PluginStore.set(
        "disteleplus",
        "allowed_updates_rev",
        DiscourseDisteleplus::ALLOWED_UPDATES_REV,
      )
      Jobs.enqueue(:disteleplus_register_webhook)
    end
  rescue StandardError => e
    Rails.logger.warn(
      "#{DiscourseDisteleplus::LOG_TAG} webhook self-heal check failed: #{e.message}",
    )
  end

  %i[user_created user_approved user_added_to_group].each do |event|
    on(event) do |first, *_rest|
      next unless DiscourseDisteleplus::ChannelNotifications.active?
      user = first.is_a?(::User) ? first : nil
      next if user.nil?
      Jobs.enqueue_in(5.seconds, :disteleplus_enforce_user_notifications, user_id: user.id)
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} notification #{event} hook failed: #{e.message}",
      )
    end
  end

  on(:post_created) do |post, *_args|
    next unless DiscourseDisteleplus::ForumPostNotifier.eligible?(post)
    Jobs.enqueue_in(10.seconds, :disteleplus_notify_forum_post, post_id: post.id)
  rescue StandardError => e
    Rails.logger.warn(
      "#{DiscourseDisteleplus::LOG_TAG} forum post notify hook failed: #{e.message}",
    )
  end

  # ── Moderation reports → Telegram ─────────────────────────────────────────

  on(:reviewable_created) do |reviewable|
    next unless DiscourseDisteleplus::Reports.enabled?
    # Small delay so scores/payload settle before the announcement renders.
    Jobs.enqueue_in(3.seconds, :disteleplus_notify_reviewable, reviewable_id: reviewable.id)
  rescue StandardError => e
    Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} reviewable hook failed: #{e.message}")
  end

  on(:reviewable_transitioned_to) do |status, reviewable|
    next unless DiscourseDisteleplus::Reports.enabled?
    next if status.to_s == "pending"
    Jobs.enqueue(:disteleplus_report_resolved, reviewable_id: reviewable.id, status: status.to_s)
  rescue StandardError => e
    Rails.logger.warn(
      "#{DiscourseDisteleplus::LOG_TAG} reviewable transition hook failed: #{e.message}",
    )
  end

  # ── Event feed → conversation ─────────────────────────────────────────────
  # Automatic system messages in the chat when selected forum events happen.

  on(:topic_created) do |topic, *_args|
    if DiscourseDisteleplus::EventFeed.on?(:topic_created)
      DiscourseDisteleplus::EventFeed.topic_created(topic)
    end
  rescue StandardError => e
    Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} event feed hook failed: #{e.message}")
  end

  on(:user_first_logged_in) do |user|
    if DiscourseDisteleplus::EventFeed.on?(:user_first_logged_in)
      DiscourseDisteleplus::EventFeed.user_first_logged_in(user)
    end
  rescue StandardError => e
    Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} event feed hook failed: #{e.message}")
  end

  on(:user_suspended) do |payload|
    if DiscourseDisteleplus::EventFeed.on?(:user_suspended)
      DiscourseDisteleplus::EventFeed.user_suspended(payload)
    end
  rescue StandardError => e
    Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} event feed hook failed: #{e.message}")
  end

  on(:user_silenced) do |payload|
    if DiscourseDisteleplus::EventFeed.on?(:user_silenced)
      DiscourseDisteleplus::EventFeed.user_silenced(payload)
    end
  rescue StandardError => e
    Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} event feed hook failed: #{e.message}")
  end

  # Admin-facing notifications (what's-new features, dashboard problems)
  # mirror into the reports topic. The per-admin fan-out is deduped inside.
  on(:notification_created) do |notification|
    DiscourseDisteleplus::Reports.maybe_bridge_admin_notification(notification)
  end

  # Official warnings: who → whom only; the PM's content stays private.
  on(:topic_created) do |topic, *_args|
    DiscourseDisteleplus::Reports.maybe_bridge_official_warning(topic)
  end

  register_problem_check ::ProblemCheck::DisteleplusTelegram if respond_to?(:register_problem_check)

  %i[post_created post_edited].each do |event|
    on(event) do |post, *_args|
      next unless DiscourseDisteleplus.enabled?
      next unless SiteSetting.disteleplus_forum_uploads_enabled
      next unless DiscourseDisteleplus::ForumUploadPolicy.eligible?(post)

      Jobs.enqueue_in(5.seconds, :disteleplus_enqueue_post_uploads, post_id: post.id)
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} forum upload #{event} hook failed: #{e.message}",
      )
    end
  end

  reloadable_patch do
    ::Guardian.prepend(
      Module.new do
        def can_access_disteleplus?
          ::DiscourseDisteleplus::Access.allowed?(user)
        end

        def can_moderate_disteleplus?
          ::DiscourseDisteleplus::Access.moderator?(user)
        end
      end,
    )
  end
end
