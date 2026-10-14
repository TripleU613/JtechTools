# frozen_string_literal: true

module DiscourseDisteleplus
  class ConversationController < ::ApplicationController
    requires_plugin "jtech-tools"
    requires_login
    before_action :ensure_enabled
    before_action :ensure_allowed

    PAGE_SIZE = 40
    MAX_PAGE_SIZE = 100

    # Ember entry point: /disteleplus renders the application shell; the
    # route then fetches the conversation JSON.
    def page
      render "default/empty"
    end

    def show
      messages = page_scope.limit(PAGE_SIZE).to_a.reverse
      render_json_dump(
        { messages: serialize_messages(messages), meta: conversation_meta(messages) },
      )
    end

    def index
      limit = params.fetch(:limit, PAGE_SIZE).to_i.clamp(1, MAX_PAGE_SIZE)
      return render_around(params[:around_id].to_i, limit) if params[:around_id].present?
      messages = page_scope.limit(limit).to_a.reverse
      render_json_dump(
        {
          messages: serialize_messages(messages),
          meta: {
            has_more: messages.any? && Message.where("id < ?", messages.first.id).exists?,
          },
        },
      )
    end

    def create
      rate_limit!("create", 30, 1.minute)
      message =
        service.create!(
          raw: params[:raw],
          upload_ids: params[:upload_ids],
          reply_to_id: params[:reply_to_id],
        )
      render_message(message, status: :created)
    rescue MessageService::Error, ActiveRecord::RecordInvalid => e
      render_error(e)
    end

    def update
      rate_limit!("update", 30, 1.minute)
      message = Message.find(params[:id])
      render_message(service.update!(message, raw: params[:raw]))
    rescue MessageService::Error, ActiveRecord::RecordInvalid => e
      render_error(e)
    end

    def destroy
      rate_limit!("delete", 20, 1.minute)
      message = Message.find(params[:id])
      render_message(service.delete!(message))
    rescue MessageService::Error, ActiveRecord::RecordInvalid => e
      render_error(e)
    end

    def add_reaction
      rate_limit!("reaction", 60, 1.minute)
      message = Message.find(params[:id])
      render_message(service.react!(message, emoji: params[:emoji], action: :add))
    rescue MessageService::Error, ActiveRecord::RecordInvalid => e
      render_error(e)
    end

    def remove_reaction
      rate_limit!("reaction", 60, 1.minute)
      message = Message.find(params[:id])
      render_message(service.react!(message, emoji: params[:emoji], action: :remove))
    rescue MessageService::Error, ActiveRecord::RecordInvalid => e
      render_error(e)
    end

    # Text is encrypted at rest, so search decrypts and filters in Ruby over a
    # bounded window — fine for one room.
    SEARCH_WINDOW = 3000
    SEARCH_LIMIT = 50

    SEARCH_OPERATOR = /\A(from|has|before|after):(.+)\z/
    SEARCH_IMAGE_EXTENSIONS = %w[png jpg jpeg gif webp avif].freeze
    SEARCH_AUDIO_EXTENSIONS = %w[mp3 m4a ogg oga opus wav aac flac].freeze
    SEARCH_VIDEO_EXTENSIONS = %w[mp4 mov mkv avi m4v].freeze

    # Query operators, WhatsApp/Discourse style: from:user · has:image /
    # voice / video / file / link / poll · before:/after:YYYY-MM-DD. The
    # rest of the query stays a plain substring match (messages are
    # encrypted at rest, so matching happens after decryption, in Ruby).
    def search
      rate_limit!("search", 30, 1.minute)
      filters = { from: nil, has: [], before: nil, after: nil }
      words = []
      params[:q]
        .to_s
        .strip
        .split(/\s+/)
        .each do |token|
          match = token.downcase.match(SEARCH_OPERATOR)
          if match.nil?
            words << token
            next
          end
          value = match[2]
          case match[1]
          when "from"
            filters[:from] = value.delete_prefix("@")
          when "has"
            filters[:has] << value
          when "before"
            filters[:before] = parse_search_date(value)
          when "after"
            filters[:after] = parse_search_date(value)
          end
        end
      term = words.join(" ").downcase
      filtered =
        filters[:from].present? || filters[:has].any? || filters[:before] || filters[:after]
      raise Discourse::InvalidParameters.new(:q) if term.length < 2 && !filtered

      scope = Message.not_deleted.includes(:user, :uploads).order(id: :desc)
      scope = scope.where("created_at < ?", filters[:before].beginning_of_day) if filters[:before]
      scope = scope.where("created_at >= ?", filters[:after].beginning_of_day) if filters[:after]
      scope = scope.where.not(poll_post_id: nil) if filters[:has].include?("poll")

      results = []
      scope
        .limit(SEARCH_WINDOW)
        .find_each(batch_size: 200) do |message|
          next unless search_matches?(message, term, filters)
          results << message
          break if results.length >= SEARCH_LIMIT
        end
      render_json_dump(
        {
          results:
            results.map do |m|
              MessageSerializer.serialize(m, viewer: current_user, include_reply: false)
            end,
          count: results.length,
        },
      )
    end

    def typing
      rate_limit!("typing", 60, 1.minute)
      Publisher.publish_typing(current_user)
      if SiteSetting.disteleplus_typing_to_telegram &&
           Discourse.redis.set("disteleplus:typing-sent", "1", ex: 4, nx: true)
        Jobs.enqueue(:disteleplus_telegram_typing)
      end
      render json: success_json
    end

    # First play of a voice note records a "listened" receipt for the sender.
    def listened
      raise Discourse::NotFound unless SiteSetting.disteleplus_read_receipts_enabled
      rate_limit!("listened", 60, 1.minute)

      message = Message.find(params[:id])
      raise Discourse::InvalidParameters.new(:id) if message.deleted_at.present?

      if message.user_id != current_user.id
        listen =
          begin
            MessageListen.find_or_create_by!(message_id: message.id, user_id: current_user.id)
          rescue ActiveRecord::RecordNotUnique
            nil
          end
        Publisher.publish_listen(message, current_user) if listen&.previously_new_record?
      end
      render json: success_json
    end

    # Read cursors of everyone else in the conversation — powers "Seen by".
    def read_states
      raise Discourse::NotFound unless SiteSetting.disteleplus_read_receipts_enabled
      rate_limit!("read-states", 30, 1.minute)

      # Groups are preloaded too: Access.allowed? reads each user's group ids.
      states =
        UserState
          .where.not(user_id: current_user.id)
          .where.not(last_read_message_id: nil)
          .includes(user: :groups)
          .order(last_read_message_id: :desc)
          .limit(100)
          .filter_map do |state|
            user = state.user
            next if user.nil? || !Access.allowed?(user)
            {
              user_id: user.id,
              username: user.username,
              name: user.name,
              avatar_template: user.avatar_template,
              last_read_message_id: state.last_read_message_id,
              # When the cursor last advanced — for the newest message this
              # IS the moment it was read, which is where the info UI opens.
              updated_at: state.updated_at&.iso8601,
            }
          end
      render_json_dump({ read_states: states })
    end

    def read
      rate_limit!("read", 120, 1.minute)
      state = service.mark_read!(params.require(:message_id))
      render_json_dump(
        {
          success: true,
          last_read_message_id: state&.last_read_message_id,
          unread_count: unread_count(state&.last_read_message_id),
          unread_mention_count: Notifier.unread(current_user).count,
        },
      )
    end

    private

    def ensure_enabled
      raise Discourse::NotFound unless DiscourseDisteleplus.enabled?
    end

    def ensure_allowed
      raise Discourse::InvalidAccess unless Access.allowed?(current_user)
    end

    def render_around(id, limit)
      half = [limit / 2, 1].max
      before =
        Message
          .includes(:user, :uploads, reply_to: :user, reactions: :user)
          .where("id < ?", id)
          .order(id: :desc)
          .limit(half)
          .to_a
          .reverse
      target =
        Message
          .includes(:user, :uploads, reply_to: :user, reactions: :user, listens: :user)
          .where(id: id)
          .to_a
      after =
        Message
          .includes(:user, :uploads, reply_to: :user, reactions: :user)
          .where("id > ?", id)
          .order(id: :asc)
          .limit(half)
          .to_a
      messages = before + target + after
      render_json_dump(
        {
          messages: serialize_messages(messages),
          meta: {
            has_more: messages.any? && Message.where("id < ?", messages.first.id).exists?,
            has_newer: messages.any? && Message.where("id > ?", messages.last.id).exists?,
          },
        },
      )
    end

    def page_scope
      scope =
        Message.includes(:user, :uploads, reply_to: :user, reactions: :user, listens: :user).order(
          id: :desc,
        )
      before_id = params[:before_id].to_i
      scope = scope.where("disteleplus_messages.id < ?", before_id) if before_id.positive?
      scope
    end

    def serialize_messages(messages)
      messages.map { |message| MessageSerializer.serialize(message, viewer: current_user) }
    end

    def conversation_meta(messages)
      state = UserState.find_by(user: current_user)
      latest_id = Message.maximum(:id)
      {
        allowed: true,
        current_user_id: current_user.id,
        latest_message_id: latest_id,
        last_read_message_id: state&.last_read_message_id,
        unread_count: unread_count(state&.last_read_message_id),
        # The header badge counts only these: messages that mention the user
        unread_mention_count: Notifier.unread(current_user).count,
        has_more: messages.any? && Message.where("id < ?", messages.first.id).exists?,
        message_bus_channel: Publisher::CHANNEL,
        # The page listens from here, so a message sent while it loads isn't lost
        message_bus_last_id: MessageBus.last_id(Publisher::CHANNEL),
        can_upload: true,
        voice_notes_enabled: SiteSetting.disteleplus_voice_notes_enabled,
        read_receipts_enabled: SiteSetting.disteleplus_read_receipts_enabled,
        polls_enabled: Polls.enabled?,
        polls_topic_id: Polls.enabled? ? SiteSetting.disteleplus_polls_topic_id : 0,
      }
    end

    def unread_count(last_read_id)
      Message
        .not_deleted
        .where("id > ?", last_read_id.to_i)
        .where.not(user_id: current_user.id)
        .count
    end

    def service
      @service ||= MessageService.new(actor: current_user)
    end

    def render_message(message, status: :ok)
      render_json_dump(
        { message: MessageSerializer.serialize(message.reload, viewer: current_user) },
        status: status,
      )
    end

    def render_error(error)
      render json: { errors: [error.message] }, status: :unprocessable_entity
    end

    def parse_search_date(value)
      Date.parse(value)
    rescue ArgumentError, TypeError
      nil
    end

    def search_matches?(message, term, filters)
      if filters[:from]
        senders = [
          message.user&.username,
          message.user&.name,
          message.external_sender_name,
        ].compact.map(&:downcase)
        return false if senders.none? { |sender| sender.include?(filters[:from]) }
      end

      filters[:has].each { |want| return false unless message_has?(message, want) }

      if term.present?
        haystack = [
          message.raw,
          message.external_sender_name,
          message.user&.username,
          message.user&.name,
        ]
        return false if haystack.compact.none? { |field| field.downcase.include?(term) }
      end

      true
    end

    def message_has?(message, want)
      uploads = message.uploads.to_a
      case want
      when "voice", "audio"
        uploads.any? do |upload|
          name = upload.original_filename.to_s.downcase
          extension = upload.extension.to_s.downcase
          name.start_with?("voice-note") || SEARCH_AUDIO_EXTENSIONS.include?(extension) ||
            (extension == "webm" && upload.width.to_i.zero?)
        end
      when "image"
        uploads.any? { |upload| SEARCH_IMAGE_EXTENSIONS.include?(upload.extension.to_s.downcase) }
      when "video"
        uploads.any? do |upload|
          extension = upload.extension.to_s.downcase
          SEARCH_VIDEO_EXTENSIONS.include?(extension) ||
            (extension == "webm" && upload.width.to_i.positive?)
        end
      when "file", "upload", "attachment"
        uploads.any?
      when "link"
        message.raw.to_s.match?(%r{https?://})
      when "poll"
        message.poll_post_id.present?
      else
        # An unknown has: value matches nothing rather than everything.
        false
      end
    end

    def rate_limit!(action, limit, interval)
      RateLimiter.new(current_user, "disteleplus-#{action}", limit, interval).performed!
    end
  end
end
