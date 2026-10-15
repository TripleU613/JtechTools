# frozen_string_literal: true

module Jobs
  # Registers (or re-registers) this forum's webhook with Telegram. Enqueued
  # by the disteleplus_register_webhook_now settings button; safe to run any
  # number of times — setWebhook is idempotent.
  class DisteleplusRegisterWebhook < ::Jobs::Base
    # Without message_reaction/poll listed explicitly Telegram never delivers
    # those update types at all. Derived from the feature toggles so the bot
    # stops receiving traffic it would discard; re-run the register button
    # after changing the polls/reactions toggles.
    def allowed_updates
      # callback_query (report action buttons) is ALWAYS listed. Telegram
      # stores allowed_updates until the next setWebhook call, so making it
      # conditional meant a press could sit spinning forever on installs whose
      # webhook was registered before reports were enabled. An unwanted
      # callback update costs one discarded job; an absent one costs the
      # feature.
      updates = %w[message edited_message callback_query]
      updates << "poll" if SiteSetting.disteleplus_bridge_polls
      updates << "message_reaction" if SiteSetting.disteleplus_bridge_reactions
      updates
    end

    def execute(_args)
      return unless DiscourseDisteleplus.enabled?
      if SiteSetting.disteleplus_bot_token.blank? || SiteSetting.disteleplus_webhook_secret.blank?
        Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} setWebhook skipped: token/secret blank")
        return
      end

      api = DiscourseDisteleplus::TelegramApi.new
      result =
        api.call(
          "setWebhook",
          url: "#{Discourse.base_url}/jtech-disteleplus/telegram/webhook",
          secret_token: SiteSetting.disteleplus_webhook_secret,
          allowed_updates: allowed_updates,
          drop_pending_updates: false,
        )

      if result.ok
        Rails.logger.info("#{DiscourseDisteleplus::LOG_TAG} setWebhook OK")
        configure_setup_commands(api)
      else
        Rails.logger.warn(
          "#{DiscourseDisteleplus::LOG_TAG} setWebhook failed: #{result.description}",
        )
      end
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} setWebhook error: #{e.class}: #{e.message}",
      )
    end

    private

    def configure_setup_commands(api)
      scope = { type: "all_chat_administrators" }
      result =
        if SiteSetting.disteleplus_setup_commands_enabled
          api.call(
            "setMyCommands",
            scope: scope,
            commands: [
              { command: "disteleplus_setup", description: "Guided setup" },
              { command: "disteleplus_status", description: "Show saved destinations" },
              { command: "disteleplus_bind_general", description: "Bind this group and General" },
              { command: "disteleplus_bind_uploads", description: "Bind this topic for uploads" },
              { command: "disteleplus_create_uploads", description: "Create the upload topic" },
              {
                command: "disteleplus_bind_reports",
                description: "Bind this topic for moderation reports",
              },
              {
                command: "disteleplus_sync_notifications",
                description: "Re-enrol members for channel notifications",
              },
            ],
          )
        else
          api.call("deleteMyCommands", scope: scope)
        end

      return if result.ok
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} setup command menu failed: #{result.description}",
      )
    end
  end
end
