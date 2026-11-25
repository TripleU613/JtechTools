# frozen_string_literal: true

module DiscourseDiscordChat
  # One line per thing the forum did in the server, in the moderators'
  # log channel. A line that can't be posted is dropped: the log is a
  # convenience and never holds up the work it describes.
  module ModLog
    def self.post(text, api: Api.new)
      channel = SiteSetting.discord_chat_mod_log_channel_id.to_s.strip
      return if channel.blank? || !DiscourseDiscordChat.configured?
      api.bot(
        :post,
        "/channels/#{channel}/messages",
        { content: text.to_s.truncate(2000), allowed_mentions: { parse: [] } },
      )
      nil
    rescue Api::Error => e
      Rails.logger.warn("#{DiscourseDiscordChat::LOG_TAG} mod log: #{e.message}")
      nil
    end
  end
end
