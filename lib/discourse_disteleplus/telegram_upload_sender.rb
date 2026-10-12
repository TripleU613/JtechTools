# frozen_string_literal: true

module DiscourseDisteleplus
  # Sends a Discourse Upload to Telegram without changing or deleting the
  # forum copy. A too-large/unreadable upload becomes a forum link message.
  class TelegramUploadSender
    MAX_SEND_BYTES = 50 * 1024 * 1024
    IMAGE_EXT = %w[png jpg jpeg webp].freeze
    VIDEO_EXT = %w[mp4 mov webm].freeze
    AUDIO_EXT = %w[mp3 m4a ogg wav flac].freeze

    Delivery = Struct.new(:message, :file_copied, keyword_init: true)

    def initialize(api: TelegramApi.new)
      @api = api
    end

    def send(upload:, caption:, chat_id:, topic_id: nil, max_bytes: MAX_SEND_BYTES)
      limit = [max_bytes.to_i, MAX_SEND_BYTES].min
      return send_link(upload, caption, chat_id, topic_id) if upload.filesize.to_i > limit

      io = self.class.upload_io(upload)
      return send_link(upload, caption, chat_id, topic_id) if io.nil?

      method, field = self.class.send_method_for(upload)
      fields = { chat_id: chat_id, caption: caption, parse_mode: "HTML" }
      thread_id = DiscourseDisteleplus.telegram_thread_id(topic_id)
      fields[:message_thread_id] = thread_id if thread_id

      begin
        result =
          @api.call_multipart(
            method,
            fields,
            file_field: field,
            io: io,
            filename: upload.original_filename,
          )
        raise "Telegram send failed: #{result.description}" unless result.ok
        Delivery.new(message: result.result, file_copied: true)
      ensure
        io.close
      end
    end

    private

    def send_link(upload, caption, chat_id, topic_id)
      url = UrlHelper.absolute(upload.url)
      payload = {
        chat_id: chat_id,
        text: "#{caption}\n<a href=\"#{ForumUploadFormatter.escape(url)}\">Open file on JTech</a>",
        parse_mode: "HTML",
      }
      thread_id = DiscourseDisteleplus.telegram_thread_id(topic_id)
      payload[:message_thread_id] = thread_id if thread_id
      result = @api.call("sendMessage", payload)
      raise "Telegram fallback send failed: #{result.description}" unless result.ok
      Delivery.new(message: result.result, file_copied: false)
    end

    # The Bot API method and field for an upload, by its extension. Also used
    # by the job that mirrors forum messages.
    def self.send_method_for(upload)
      ext = upload.extension.to_s.downcase
      if IMAGE_EXT.include?(ext)
        %w[sendPhoto photo]
      elsif ext == "gif"
        %w[sendAnimation animation]
      elsif VIDEO_EXT.include?(ext)
        %w[sendVideo video]
      elsif AUDIO_EXT.include?(ext)
        %w[sendAudio audio]
      else
        %w[sendDocument document]
      end
    end

    def self.upload_io(upload)
      if Discourse.store.external?
        Discourse.store.download(upload)
      else
        path = Discourse.store.path_for(upload)
        path && File.exist?(path) ? File.open(path, "rb") : nil
      end
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} upload read failed: #{e.message}")
      nil
    end
  end
end
