# frozen_string_literal: true

module DiscourseModCategories
  # A whisper doesn't raise Topic#highest_post_number (Whisper.
  # refresh_topic_counters rolls it back, as core does for its own
  # whispers), so for everyone outside its audience it never counts as new.
  # Staff are core "whisperers" and read highest_staff_post_number. What's
  # left is the non-staff audience — the users, groups and badge holders a
  # whisper names — who should see it count as unread and be able to mark
  # it read.
  module WhisperUnread
    # Topics with a whisper past the last public post are the only ones
    # where a non-staff reader's number can differ, so the per-topic query
    # runs only for those rows.
    def self.trailing_whispers?(topic)
      staff_max = topic.highest_staff_post_number
      staff_max.present? && staff_max > topic.highest_post_number.to_i
    end

    def self.visible_max_post_number(topic, user)
      return nil if user.nil? || !trailing_whispers?(topic)
      DiscourseModCategories.whisper_audience_max_post_number(topic, user)
    end

    # Core's tracking state (the sidebar, the topic list's unread dot) gives
    # every whisperer highest_staff_post_number. A whisperer who can't open a
    # trailing whisper (a moderator facing an admin's, or a member of
    # whispers_allowed_groups it doesn't name) can never send a timing for
    # it, so the topic stayed unread after they'd read all of it. Moving
    # their last read past the whispers they can't see fixes every surface
    # at once.
    def self.skip_hidden_whispers!(user, topic_id)
      return unless SiteSetting.mod_whisper_audience_aware_topic_list
      return if !user.is_a?(::User) || user.admin? || !user.whisperer?
      topic = ::Topic.find_by(id: topic_id)
      return if topic.nil? || !trailing_whispers?(topic)

      staff_max = topic.highest_staff_post_number
      topic_user = ::TopicUser.find_by(user_id: user.id, topic_id: topic.id)
      return if topic_user.nil? || topic_user.last_read_post_number.to_i >= staff_max

      visible = DiscourseModCategories.whisper_audience_max_post_number(topic, user).to_i
      return if topic_user.last_read_post_number.to_i < visible

      ::TopicUser.where(id: topic_user.id).update_all(last_read_post_number: staff_max)
      ::TopicTrackingState.publish_read(topic.id, staff_max, user)
    end

    # The same for a new whisper: whisperers outside its audience who had
    # read up to it stay caught up instead of seeing the topic turn unread.
    def self.skip_new_whisper!(post)
      return unless SiteSetting.mod_whisper_audience_aware_topic_list
      whisper_group_ids = SiteSetting.whispers_allowed_groups_map
      return if whisper_group_ids.empty?
      audience_ids = DiscourseModCategories::Whisper.audience_user_ids(post)
      return if audience_ids.nil?

      ::DB.exec(
        <<~SQL,
          UPDATE topic_users SET last_read_post_number = :post_number
          WHERE topic_id = :topic_id
            AND last_read_post_number = :post_number - 1
            AND user_id NOT IN (:audience_ids)
            AND user_id IN (
              SELECT user_id FROM group_users WHERE group_id IN (:whisper_group_ids)
            )
        SQL
        post_number: post.post_number,
        topic_id: post.topic_id,
        audience_ids: audience_ids.presence || [-1],
        whisper_group_ids: whisper_group_ids,
      )
    end

    module SerializerExtension
      def highest_post_number
        value = super
        return value unless SiteSetting.mod_whisper_audience_aware_topic_list
        user = scope.user
        if user&.moderator? && !user.admin?
          # A moderator is a whisperer, so core gave them the staff number,
          # which counts admins' whispers they can't open: they'd show as new
          # for good. Core's tracking-state SQL still counts them; for that,
          # skip_hidden_whispers! moves their last read past them.
          visible = DiscourseModCategories::WhisperUnread.visible_max_post_number(object, user)
          return visible && visible < value ? visible : value
        end
        return value if scope.is_whisperer?

        visible = DiscourseModCategories::WhisperUnread.visible_max_post_number(object, scope.user)
        visible && visible > value ? visible : value
      end
    end

    # PostTiming.process_timings drops timings past the topic's
    # highest_post_number for non-whisperers, so an audience member could
    # never record reading a whisper that is the last post and its unread
    # badge would stick. For that one call they are treated as a whisperer
    # (the timings they can send are for posts their client rendered).
    module PostTimingExtension
      def process_timings(current_user, topic_id, topic_time, timings, opts = {})
        if current_user && !current_user.whisperer? &&
             SiteSetting.mod_whisper_audience_aware_topic_list &&
             (topic = ::Topic.find_by(id: topic_id)) &&
             (
               visible =
                 DiscourseModCategories::WhisperUnread.visible_max_post_number(topic, current_user)
             ) && visible > topic.highest_post_number.to_i
          begin
            Thread.current[:mod_whisper_timing_user_id] = current_user.id
            return super
          ensure
            Thread.current[:mod_whisper_timing_user_id] = nil
          end
        end
        result = super
        DiscourseModCategories::WhisperUnread.skip_hidden_whispers!(current_user, topic_id)
        result
      end
    end

    module UserExtension
      def whisperer?
        return true if id && Thread.current[:mod_whisper_timing_user_id] == id
        super
      end
    end
  end
end
