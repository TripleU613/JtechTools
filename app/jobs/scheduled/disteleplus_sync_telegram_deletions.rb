# frozen_string_literal: true

module Jobs
  # Deletes here what was deleted on Telegram (DiscourseDisteleplus::
  # DeletionSync): Telegram doesn't say, so the bridge checks. Off until a
  # check channel is set, and with disteleplus_bridge_deletes off.
  class DisteleplusSyncTelegramDeletions < ::Jobs::Scheduled
    every 5.minutes

    def execute(_args)
      return unless DiscourseDisteleplus.enabled? && SiteSetting.disteleplus_bridge_deletes
      chat_id = SiteSetting.disteleplus_telegram_chat_id.to_s.strip
      check_chat_id = SiteSetting.disteleplus_deletion_check_chat_id.to_s.strip
      return if chat_id.blank? || check_chat_id.blank?

      DiscourseDisteleplus::DeletionSync.new(chat_id: chat_id, check_chat_id: check_chat_id).run
    rescue DiscourseDisteleplus::TelegramApi::RateLimited
      # the next run carries on
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} deletion check failed: #{e.class}: #{e.message}",
      )
    end
  end
end
