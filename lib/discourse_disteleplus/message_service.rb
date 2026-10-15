# frozen_string_literal: true

module DiscourseDisteleplus
  class MessageService
    class Error < StandardError
    end

    attr_reader :actor

    def initialize(actor:, bypass_access: false)
      @actor = actor
      @bypass_access = bypass_access
      ensure_access!
    end

    def create!(
      raw: "",
      upload_ids: nil,
      reply_to_id: nil,
      source: :discourse,
      external_sender_name: nil,
      bridge: true,
      notify: true,
      created_at: nil
    )
      raw = raw.to_s
      uploads = resolve_uploads(upload_ids)
      raise Error, "message or upload required" if raw.blank? && uploads.empty?

      reply_to = resolve_reply(reply_to_id)
      message = nil
      Message.transaction do
        message =
          Message.create!(
            user: actor,
            raw: raw,
            cooked: cook(raw),
            source: source,
            external_sender_name: external_sender_name.to_s.strip.presence,
            reply_to: reply_to,
            created_at: created_at || Time.zone.now,
            updated_at: created_at || Time.zone.now,
          )
        uploads.each { |upload| message.message_uploads.create!(upload: upload) }
      end

      if message.source_discourse? && Polls.enabled? && Polls.poll_markup?(raw)
        Polls.create_backing_post!(message)
      end

      Publisher.publish(:created, message, actor: actor)
      Notifier.notify(message, actor: actor) if notify
      enqueue_bridge("create", message) if bridge && message.source_discourse?
      enqueue_process(message)
      message
    end

    def update!(message, raw:, bridge: true)
      ensure_editable!(message)
      raw = raw.to_s
      raise Error, "message cannot be blank" if raw.blank? && message.uploads.empty?

      message.update!(raw: raw, cooked: cook(raw), edited_at: Time.zone.now)
      Publisher.publish(:edited, message, actor: actor)
      enqueue_bridge("edit", message) if bridge && message.source_discourse?
      enqueue_process(message)
      message
    end

    def update_from_telegram!(message, raw:)
      raise Error, "not a Telegram message" unless message.source_telegram?

      message.update!(raw: raw.to_s, cooked: cook(raw.to_s), edited_at: Time.zone.now)
      Publisher.publish(:edited, message, actor: actor)
      message
    end

    def delete!(message, bridge: true)
      ensure_deletable!(message)
      Polls.destroy_backing_post(message)
      message.update!(deleted_at: Time.zone.now, raw: "", cooked: "")
      message.message_uploads.destroy_all
      message.reactions.destroy_all
      Publisher.publish(:deleted, message, actor: actor)
      # Whichever side it was written on: a message deleted here goes on
      # Telegram too, the humans' own messages included
      enqueue_bridge("delete", message) if bridge
      message
    end

    def react!(message, emoji:, action:, bridge: true)
      raise Error, "cannot react to a deleted message" if message.deleted?
      normalized = normalize_emoji(emoji)

      case action.to_sym
      when :add
        Reaction.find_or_create_by!(message: message, user: actor, emoji: normalized)
      when :remove
        Reaction.where(message: message, user: actor, emoji: normalized).destroy_all
      else
        raise Error, "unknown reaction action"
      end

      message.reload
      Publisher.publish(:reaction_changed, message, actor: actor)
      if bridge
        enqueue_bridge(
          "react",
          message,
          reactor_id: actor&.id,
          emoji: normalized,
          reaction_action: action.to_s,
        )
      end
      message
    end

    def mark_read!(message_id)
      message = Message.find_by(id: message_id.to_i)
      return nil if message.nil?

      state = UserState.find_or_create_by!(user: actor)
      previous = state.last_read_message_id.to_i
      state.advance_to!(message.id)
      Notifier.mark_read(actor, message.id)
      if state.last_read_message_id.to_i > previous
        Publisher.publish_read_state(actor, state.last_read_message_id)
      end
      state
    end

    private

    def ensure_access!
      return if @bypass_access
      raise Discourse::InvalidAccess unless Access.allowed?(actor)
    end

    def ensure_editable!(message)
      return if @bypass_access
      raise Discourse::InvalidAccess unless Access.can_edit?(actor, message)
    end

    def ensure_deletable!(message)
      return if @bypass_access
      raise Discourse::InvalidAccess unless Access.can_delete?(actor, message)
    end

    def resolve_uploads(upload_ids)
      ids = Array(upload_ids).map(&:to_i).reject(&:zero?).uniq
      return [] if ids.empty?
      raise Error, "too many uploads" if ids.length > 10

      uploads = Upload.where(id: ids).to_a
      raise Error, "upload not found" unless uploads.length == ids.length
      unless @bypass_access || actor&.admin? ||
               uploads.all? { |upload| upload.user_id == actor&.id }
        raise Discourse::InvalidAccess
      end
      uploads.index_by(&:id).values_at(*ids)
    end

    def resolve_reply(reply_to_id)
      return nil if reply_to_id.blank?
      Message.find_by(id: reply_to_id.to_i) || raise(Error, "reply target not found")
    end

    def cook(raw)
      self.class.cook_with_oneboxes(raw, user_id: actor&.id)
    end

    # Cooks and inlines any already-cached oneboxes (Chat does the same); the
    # process job fetches uncached ones afterwards and re-cooks.
    def self.cook_with_oneboxes(raw, user_id: nil)
      return "" if raw.blank?
      cooked = PrettyText.cook(raw, user_id: user_id)
      doc = Nokogiri::HTML5.fragment(cooked)
      result = Oneboxer.apply(doc) { |url| Oneboxer.cached_onebox(url) }
      result.changed? ? result.to_html : cooked
    rescue StandardError => e
      Rails.logger.warn("#{DiscourseDisteleplus::LOG_TAG} onebox apply failed: #{e.message}")
      cooked || ""
    end

    def normalize_emoji(emoji)
      value = emoji.to_s.delete(":").strip
      raise Error, "invalid emoji" unless value.match?(/\A[\p{L}\p{N}_+\-]{1,100}\z/u)
      value
    end

    def enqueue_process(message)
      return if message.raw.blank? || !message.raw.match?(%r{https?://})
      Jobs.enqueue(:disteleplus_process_message, message_id: message.id)
    end

    def enqueue_bridge(action, message, **extra)
      return unless DiscourseDisteleplus.enabled?
      Jobs.enqueue(:disteleplus_send_to_telegram, action: action, message_id: message.id, **extra)
    end
  end
end
