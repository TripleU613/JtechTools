# frozen_string_literal: true

module DiscourseModCategories
  # Slow mode for one user: one public post (a reply or a new topic) every so
  # often, for a while or until lifted. Core's slow mode is per topic, and its
  # post rate limits are per site or trust level; neither reaches one person.
  #
  # Personal messages and edits are never limited. A post waiting for approval
  # holds the user back until it's reviewed, so the review queue can't be used
  # to post several at once.
  module UserSlowMode
    SECONDS_FIELD = "mod_slow_mode_seconds"
    UNTIL_FIELD = "mod_slow_mode_until"

    MIN_SECONDS = 1.minute.to_i
    MAX_SECONDS = 7.days.to_i
    REASON_MAX_LENGTH = 1000

    State = Struct.new(:seconds, :ends_at, keyword_init: true)

    def self.enabled?
      DiscourseModCategories.enabled? && SiteSetting.mod_user_slow_mode_enabled
    end

    # The user's slow mode, or nil when they have none or it has run out.
    def self.state_for(user)
      return nil if user.nil?

      seconds = user.custom_fields[SECONDS_FIELD].to_i
      return nil if seconds <= 0

      ends_at = parse_time(user.custom_fields[UNTIL_FIELD])
      return nil if ends_at && ends_at <= Time.zone.now

      State.new(seconds: seconds, ends_at: ends_at)
    end

    def self.set!(user, actor:, seconds:, ends_at:, reason:)
      user.custom_fields[SECONDS_FIELD] = seconds
      user.custom_fields[UNTIL_FIELD] = ends_at&.iso8601
      user.save_custom_fields(true)

      log(
        actor,
        "mod_user_slow_mode_set",
        user,
        interval: interval_words(seconds),
        until: ends_at&.iso8601 || "no end",
        reason: reason,
      )
      SystemMessage.create_from_system_user(
        user,
        :mod_user_slow_mode_set,
        interval: interval_words(seconds),
        ends: ends_text(user, ends_at),
        reason: reason,
      )
    end

    def self.lift!(user, actor:)
      user.custom_fields.delete(SECONDS_FIELD)
      user.custom_fields.delete(UNTIL_FIELD)
      user.save_custom_fields(true)

      log(actor, "mod_user_slow_mode_lifted", user)
      SystemMessage.create_from_system_user(user, :mod_user_slow_mode_lifted)
    end

    # The NewPostManager check: nil to let the post through, or a failed
    # result saying when the user can post again.
    def self.check(manager)
      return nil unless enabled?

      user = manager.user
      return nil if user.nil? || user.staff?
      return nil if private_message?(manager.args)

      state = state_for(user)
      return nil if state.nil?

      return refusal(I18n.t("discourse_mod_categories.slow_mode.waiting")) if waiting?(user)

      next_at = next_post_at(user, state)
      return nil if next_at.nil?

      wait = (next_at - Time.zone.now).ceil
      return nil if wait <= 0

      refusal(
        I18n.t(
          "discourse_mod_categories.slow_mode.too_soon",
          time_left: RateLimiter.time_left(wait),
        ),
      )
    end

    # When the user may next post publicly, or nil if they may now (slow mode
    # aside from a post waiting for approval, which `waiting?` covers).
    def self.next_post_at(user, state)
      last = last_public_post_at(user, state.seconds.seconds.ago)
      return nil if last.nil?

      next_at = last + state.seconds
      next_at > Time.zone.now ? next_at : nil
    end

    # Their latest reply or topic in a public topic since `since`. Deleted
    # posts and topics count: deleting a post doesn't buy another one.
    def self.last_public_post_at(user, since)
      Post
        .with_deleted
        .joins("INNER JOIN topics ON topics.id = posts.topic_id")
        .where(user_id: user.id, post_type: Post.types[:regular])
        .where(topics: { archetype: Archetype.default })
        .where("posts.created_at > ?", since)
        .maximum(:created_at)
    end

    # Core never queues personal messages, so every pending queued post is a
    # public one.
    def self.waiting?(user)
      ReviewableQueuedPost.pending.where(target_created_by_id: user.id).exists?
    end

    # What the user's own composer needs.
    def self.summary_for(user)
      state = state_for(user)
      return nil if state.nil?

      {
        seconds: state.seconds,
        ends_at: state.ends_at&.iso8601,
        next_post_at: next_post_at(user, state)&.iso8601,
        waiting: waiting?(user),
      }
    end

    # What staff see on the user's admin page.
    def self.admin_summary_for(user)
      state = state_for(user)
      return nil if state.nil?

      { seconds: state.seconds, ends_at: state.ends_at&.iso8601 }
    end

    def self.private_message?(args)
      return true if args[:archetype] == Archetype.private_message
      return true if args[:target_recipients].present?

      args[:topic_id].present? &&
        Topic.where(id: args[:topic_id], archetype: Archetype.private_message).exists?
    end

    def self.refusal(message)
      result = NewPostResult.new(:created_post, false)
      result.errors.add(:base, message)
      result
    end

    # "15 minutes", "1 hour 30 minutes", in core's rate-limit words.
    # (RateLimiter.time_left rounds down to whole hours.)
    def self.interval_words(seconds)
      hours, rest = seconds.to_i.divmod(1.hour.to_i)
      minutes = rest / 1.minute.to_i
      parts = []
      parts << I18n.t("rate_limiter.hours", count: hours) if hours > 0
      parts << I18n.t("rate_limiter.minutes", count: minutes) if minutes > 0
      parts.join(" ")
    end

    # In the user's own time zone and language, for their message.
    def self.ends_text(user, ends_at)
      I18n.with_locale(user.effective_locale) do
        next I18n.t("discourse_mod_categories.slow_mode.no_end") if ends_at.nil?

        zone = user.user_option&.timezone.presence || "UTC"
        I18n.t(
          "discourse_mod_categories.slow_mode.until",
          time: "#{I18n.l(ends_at.in_time_zone(zone), format: :long)} (#{zone})",
        )
      end
    end

    def self.parse_time(value)
      return nil if value.blank?

      Time.zone.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def self.log(actor, type, user, **details)
      UserHistory.create!(
        action: UserHistory.actions[:custom_staff],
        custom_type: type,
        acting_user_id: actor.id,
        target_user_id: user.id,
        details: details.map { |key, value| "#{key}: #{value.to_s.truncate(500)}" }.join("\n"),
      )
    end
  end
end
