# frozen_string_literal: true

module DiscourseDisteleplus
  # Telegram never tells a bot that a message in a group was deleted (the Bot
  # API has deletion updates for business accounts only), so a message
  # deleted on Telegram stayed on the forum. This finds them: it copies the
  # bridged messages into a private check channel the bot owns
  # (disteleplus_deletion_check_chat_id) and deletes the copies at once.
  # copyMessages skips a message it can't find, so a batch that copies whole
  # has none gone; a short one is halved until the gone ones are found, each
  # confirmed on its own by Telegram's "not found". A message that can't be
  # copied (a service message, a quiz) or any error (the channel gone, rights
  # missing) counts as still there: only Telegram saying "not found" deletes.
  #
  # The last hour's messages are checked every run; older ones, up to a week,
  # a twelfth each run, so each about hourly with runs five minutes apart.
  # ponytail: one hour / one week tiers; a busy group checking more often
  # would want per-message last-checked times.
  class DeletionSync
    RECENT = 1.hour
    WINDOW = 7.days
    SLOTS = 12
    BATCH = 100
    # Telegram's words for a message it can't find. Only about the message:
    # "chat not found" (the check channel gone) must never read as deleted.
    NOT_FOUND = /\bmessages? to (copy|forward) not found\b|\bmessage not found\b/i

    def initialize(chat_id:, check_chat_id:, api: TelegramApi.new, now: Time.zone.now)
      @chat_id = chat_id.to_s
      @check_chat_id = check_chat_id.to_s
      @api = api
      @now = now
    end

    # Returns the forum messages it deleted
    def run
      ids = candidate_ids
      gone = ids.each_slice(BATCH).flat_map { |batch| missing(batch) }.to_set
      return [] if gone.empty?

      links =
        MessageLink.where(telegram_chat_id: @chat_id.to_i).where.not(disteleplus_message_id: nil)
      messages =
        Message.not_deleted.where(
          id: links.where(telegram_message_id: gone.to_a).select(:disteleplus_message_id),
        )
      messages
        .select { |message| all_gone?(message, links, gone) }
        .each { |message| delete(message, links) }
    end

    private

    def candidate_ids
      links =
        MessageLink
          .joins(:message)
          .merge(Message.not_deleted)
          .where(telegram_chat_id: @chat_id.to_i)
          .where("disteleplus_message_links.created_at > ?", @now - WINDOW)
      slot = (@now.to_i / 5.minutes) % SLOTS
      links
        .where(
          "disteleplus_message_links.created_at > ? OR disteleplus_message_links.telegram_message_id % ? = ?",
          @now - RECENT,
          SLOTS,
          slot,
        )
        .distinct
        .order(:telegram_message_id)
        .pluck(:telegram_message_id)
    end

    def missing(ids)
      return gone?(ids.first) ? ids : [] if ids.size == 1

      result =
        @api.call(
          "copyMessages",
          chat_id: @check_chat_id,
          from_chat_id: @chat_id,
          message_ids: ids,
          disable_notification: true,
        )
      # A batch with nothing left to copy can come back as an error instead
      # of an empty list: "not found" is split and confirmed like a short
      # batch, any other error leaves the lot
      if !result.ok
        return [] unless result.description.to_s.match?(NOT_FOUND)
      else
        copies = Array(result.result).map { |copy| copy["message_id"] }
        discard(copies)
        return [] if copies.size == ids.size
      end

      half = ids.size / 2
      missing(ids[0...half]) + missing(ids[half..])
    end

    def gone?(id)
      result =
        @api.call(
          "copyMessage",
          chat_id: @check_chat_id,
          from_chat_id: @chat_id,
          message_id: id,
          disable_notification: true,
        )
      if result.ok
        discard([result.result["message_id"]])
        false
      else
        result.description.to_s.match?(NOT_FOUND)
      end
    end

    def discard(copy_ids)
      return if copy_ids.empty?
      @api.call("deleteMessages", chat_id: @check_chat_id, message_ids: copy_ids)
    end

    # A forum message with pictures went out as several Telegram messages:
    # it goes when all of them have
    def all_gone?(message, links, gone)
      links
        .where(disteleplus_message_id: message.id)
        .pluck(:telegram_message_id)
        .all? { |id| gone.include?(id) }
    end

    def delete(message, links)
      MessageService.new(actor: Discourse.system_user, bypass_access: true).delete!(
        message,
        bridge: false,
      )
      links.where(disteleplus_message_id: message.id).destroy_all
      Rails.logger.info("#{LOG_TAG} message #{message.id} deleted on Telegram, deleted here too")
      message
    end
  end
end
