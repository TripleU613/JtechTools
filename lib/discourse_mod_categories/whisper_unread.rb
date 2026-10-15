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

    module SerializerExtension
      def highest_post_number
        value = super
        return value unless SiteSetting.mod_whisper_audience_aware_topic_list
        user = scope.user
        if user&.moderator? && !user.admin?
          # A moderator is a whisperer, so core gave them the staff number,
          # which counts admins' whispers they can't open: they'd show as new
          # for good. ponytail: the sidebar's New/Unread counts (core's
          # tracking-state SQL) still count them; per-moderator SQL there if
          # it matters.
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
        super
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
