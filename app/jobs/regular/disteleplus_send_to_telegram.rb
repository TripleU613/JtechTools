# frozen_string_literal: true

module Jobs
  # Pushes one Discourse chat action (create/edit/delete/react) to the
  # Telegram group. Enqueued by DiscourseDisteleplus.handle_chat_event /
  # handle_reaction_event, which have already done the channel/echo gating.
  #
  # Telegram cannot batch mixed media, so a chat message with N uploads fans
  # out to N Telegram messages (the first carries the author-prefixed text as
  # its caption); each gets its own MessageLink row and the first one — the
  # lowest telegram_message_id — is the edit target.
  class DisteleplusSendToTelegram < ::Jobs::Base
    Sender = DiscourseDisteleplus::TelegramUploadSender

    def execute(args)
      return unless DiscourseDisteleplus.enabled?

      @api = DiscourseDisteleplus::TelegramApi.new
      # Strip: a pasted trailing space in the setting makes Telegram answer
      # "chat not found" for an otherwise-correct id.
      @chat_id = SiteSetting.disteleplus_telegram_chat_id.to_s.strip
      # nil for General (0 or 1) — see DiscourseDisteleplus.telegram_thread_id.
      @thread_id = DiscourseDisteleplus.telegram_thread_id(SiteSetting.disteleplus_chat_topic_id)
      return if @chat_id.blank?

      case args[:action]
      when "create"
        handle_create(args[:message_id])
      when "edit"
        handle_edit(args[:message_id])
      when "delete"
        handle_delete(args[:message_id])
      when "react"
        handle_react(args[:message_id], args)
      end
    rescue DiscourseDisteleplus::TelegramApi::RateLimited => e
      Jobs.enqueue_in(
        e.retry_after.seconds,
        :disteleplus_send_to_telegram,
        args.slice(:action, :message_id, :reactor_id, :emoji, :reaction_action),
      )
    rescue StandardError => e
      Rails.logger.warn(
        "#{DiscourseDisteleplus::LOG_TAG} outbound #{args[:action]} failed: #{e.class}: #{e.message}",
      )
    end

    private

    def handle_create(message_id)
      message = DiscourseDisteleplus::Message.find_by(id: message_id)
      return if message.nil?
      return if DiscourseDisteleplus::MessageLink.for_message(message.id).exists?

      html = outbound_html(message)
      reply_to = reply_target(message)
      uploads = message.uploads.to_a
      # The uploads toggle gates both directions — inbound is checked in
      # UpdateProcessor#process_media.
      uploads = [] unless SiteSetting.disteleplus_bridge_uploads

      sent = [] # [[telegram_message, kind], ...]
      if uploads.blank?
        sent << [send_text(html, reply_to, preview: preview_options(message.raw)), :text]
      else
        uploads.each_with_index do |upload, index|
          caption = index.zero? ? html : nil
          sent << send_upload(upload, caption, index.zero? ? reply_to : nil)
        end
      end

      sent.each do |tg_message, kind|
        next if tg_message.nil?
        DiscourseDisteleplus::MessageLink.create!(
          telegram_chat_id: @chat_id,
          telegram_message_id: tg_message["message_id"],
          disteleplus_message_id: message.id,
          direction: :discourse_to_tg,
          kind: kind,
        )
      end
    end

    def handle_edit(message_id)
      # The toggle gates both directions — inbound is checked in
      # UpdateProcessor#handle_edit.
      return unless SiteSetting.disteleplus_bridge_edits
      link = DiscourseDisteleplus::MessageLink.for_message(message_id).discourse_to_tg.first
      return if link.nil?

      message = DiscourseDisteleplus::Message.find_by(id: message_id)
      return if message.nil?

      html = outbound_html(message)
      payload = { chat_id: @chat_id, message_id: link.telegram_message_id, parse_mode: "HTML" }
      if link.kind_text?
        @api.call(
          "editMessageText",
          payload.merge(text: html, link_preview_options: preview_options(message.raw)),
        )
      else
        @api.call("editMessageCaption", payload.merge(caption: html))
      end
    end

    def handle_delete(message_id)
      # Honor the toggle: with it off, the Discourse-side delete stands but
      # the Telegram copy is left alone (and stays linked for the record).
      return unless SiteSetting.disteleplus_bridge_deletes
      # Both directions: the bot's copies of forum messages, and the
      # originals of messages written on Telegram (which takes the bot's
      # "Delete messages" admin right in the group)
      DiscourseDisteleplus::MessageLink
        .for_message(message_id)
        .find_each do |link|
          result =
            @api.call("deleteMessage", chat_id: @chat_id, message_id: link.telegram_message_id)
          unless result.ok
            # Older than 48h or missing delete rights — log, still unlink.
            Rails.logger.warn(
              "#{DiscourseDisteleplus::LOG_TAG} delete failed: #{result.description}",
            )
          end
          link.destroy!
        end
    end

    # Mirrors the message's most recent Discourse reaction as the bot's ONE
    # allowed Telegram reaction; an empty reaction list clears it. Because
    # that single bot reaction cannot say WHO reacted, an added reaction also
    # posts a small "<name> reacted 👍" reply under the Telegram copy.
    def handle_react(message_id, args = {})
      link = DiscourseDisteleplus::MessageLink.for_message(message_id).first
      return if link.nil?

      send_reaction_notice(link, args) if args[:reaction_action].to_s == "add"

      emojis =
        DiscourseDisteleplus::Reaction
          .where(message_id: message_id)
          .order(:created_at)
          .pluck(:emoji)
      reaction =
        if emojis.any?
          [{ type: "emoji", emoji: DiscourseDisteleplus::EmojiMap.discourse_to_tg(emojis.last) }]
        else
          []
        end

      @api.call(
        "setMessageReaction",
        chat_id: @chat_id,
        message_id: link.telegram_message_id,
        reaction: reaction,
      )
    end

    def send_reaction_notice(link, args)
      return unless SiteSetting.disteleplus_bridge_reaction_notices
      reactor = User.find_by(id: args[:reactor_id])
      return if reactor.nil? || reactor.id == DiscourseDisteleplus.bot_user&.id

      emoji = DiscourseDisteleplus::Formatter.emojify(":#{args[:emoji]}:").to_s
      emoji = DiscourseDisteleplus::EmojiMap.discourse_to_tg(args[:emoji]) if emoji.start_with?(":")
      name = DiscourseDisteleplus::Formatter.escape_html(reactor.name.presence || reactor.username)
      profile = "#{Discourse.base_url}/u/#{reactor.username_lower}"
      text =
        "<a href=\"#{profile}\"><b>#{name}</b></a> " \
          "#{DiscourseDisteleplus::Formatter.escape_html(I18n.t("disteleplus.reaction_notice", emoji: emoji))}"

      payload = {
        chat_id: @chat_id,
        text: text,
        parse_mode: "HTML",
        link_preview_options: {
          is_disabled: true,
        },
        reply_to_message_id: link.telegram_message_id,
        disable_notification: true,
      }
      payload[:message_thread_id] = @thread_id if @thread_id
      result = @api.call("sendMessage", payload)
      log_send_failure(result) unless result.ok
    end

    # ── send helpers ─────────────────────────────────────────────────────────

    def send_text(html, reply_to, preview: { is_disabled: true })
      payload = { chat_id: @chat_id, text: html, parse_mode: "HTML", link_preview_options: preview }
      payload[:message_thread_id] = @thread_id if @thread_id
      payload[:reply_to_message_id] = reply_to if reply_to
      result = @api.call("sendMessage", payload)
      result.ok ? result.result : log_send_failure(result)
    end

    # The author header is a link to the sender's Discourse profile; without
    # this Telegram picks that first URL for its preview card and renders the
    # user's profile page — avatar, bio and all — under every message. Point
    # the preview at the first URL in the body instead, or turn it off when
    # the body has none.
    def preview_options(raw)
      url = raw.to_s[%r{https?://[^\s)\]>]+}]
      url ? { url: url } : { is_disabled: true }
    end

    # → [telegram_message, kind] (either may be nil on failure).
    def send_upload(upload, caption, reply_to)
      max_bytes = [SiteSetting.disteleplus_max_upload_mb.megabytes, Sender::MAX_SEND_BYTES].min
      if upload.filesize.to_i > max_bytes
        # Too big to push — send the forum URL instead (login-gated when
        # secure uploads are on; documented in the README).
        url = UrlHelper.absolute(upload.url)
        text = [caption, "📎 #{upload.original_filename}: #{url}"].compact.join("\n")
        return send_text(text, reply_to), :text
      end

      io = Sender.upload_io(upload)
      if io.nil?
        return [
          send_text([caption, "📎 #{upload.original_filename}"].compact.join("\n"), reply_to),
          :text
        ]
      end

      # Voice notes become real Telegram voice bubbles (sendVoice, transcoded
      # to OGG/OPUS when needed); everything else routes by extension.
      method, field, io, filename, mime =
        DiscourseDisteleplus::VoiceNotes.telegram_send_plan(upload, io)
      method, field = Sender.send_method_for(upload) if method.nil?
      filename = upload.original_filename if filename.blank?

      fields = { chat_id: @chat_id }
      fields[:message_thread_id] = @thread_id if @thread_id
      fields[:caption] = caption if caption.present?
      fields[:parse_mode] = "HTML" if caption.present?
      fields[:reply_to_message_id] = reply_to if reply_to

      begin
        multipart = { file_field: field, io: io, filename: filename }
        multipart[:mime] = mime if mime.present?
        result = @api.call_multipart(method, fields, **multipart)
        result.ok ? [result.result, :media] : [log_send_failure(result), nil]
      ensure
        io.close if io.respond_to?(:close)
        io.unlink if io.respond_to?(:unlink)
      end
    end

    def reply_target(message)
      in_reply_to_id = message.reply_to_id
      return nil if in_reply_to_id.blank?
      DiscourseDisteleplus::MessageLink.for_message(in_reply_to_id).first&.telegram_message_id
    end

    def author_name(message)
      message.user&.username || "unknown"
    end

    def outbound_html(message)
      user = message.user
      raw = message.raw
      # A poll bridges as its question plus a deep link — bots cannot cast
      # Telegram votes, so the forum poll is the only real ballot box.
      if message.poll_post_id.present?
        question = DiscourseDisteleplus::Polls.question_text(raw)
        raw =
          "📊 #{question.presence || "Poll"}\n\nVote in the conversation: " \
            "#{Discourse.base_url}/disteleplus#m#{message.id}"
      end
      DiscourseDisteleplus::Formatter.outbound_html(
        author_name(message),
        raw,
        display_name: user&.name.presence || user&.username,
        profile_url: user ? "#{Discourse.base_url}/u/#{user.username_lower}" : nil,
      )
    end

    def log_send_failure(result)
      Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} send failed: #{result.description}")
      DiscourseDisteleplus::Health.record_error(result.description, context: "outbound")
      nil
    end
  end
end
