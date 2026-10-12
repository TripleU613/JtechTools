# frozen_string_literal: true

module Jobs
  # Admin "send a test message" toggle: proves token, chat id and topic id
  # together, and records the failure for the dashboard problem check.
  class DisteleplusSendTestMessage < ::Jobs::Base
    def execute(_args)
      return unless DiscourseDisteleplus.enabled?
      chat_id = SiteSetting.disteleplus_telegram_chat_id.to_s.strip
      if chat_id.blank?
        DiscourseDisteleplus::Health.record_error(
          "chat not found: disteleplus_telegram_chat_id is blank",
          context: "test",
        )
        return
      end

      payload = {
        chat_id: chat_id,
        text:
          I18n.t(
            "disteleplus.test_message",
            site: DiscourseDisteleplus::Formatter.escape_html(SiteSetting.title),
            url: Discourse.base_url + "/disteleplus",
          ),
        parse_mode: "HTML",
      }
      thread_id = DiscourseDisteleplus.telegram_thread_id(SiteSetting.disteleplus_chat_topic_id)
      payload[:message_thread_id] = thread_id if thread_id
      result = DiscourseDisteleplus::TelegramApi.new.call("sendMessage", payload)
      if result.ok
        DiscourseDisteleplus::Health.clear!
        Rails.logger.info("#{DiscourseDisteleplus::LOG_TAG} test message delivered to #{chat_id}")
      else
        DiscourseDisteleplus::Health.record_error(result.description, context: "test")
        Rails.logger.warn(
          "#{DiscourseDisteleplus::LOG_TAG} test message failed: #{result.description}",
        )
      end
    end
  end
end
