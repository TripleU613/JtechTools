# frozen_string_literal: true

module DiscourseModCategories
  # Filter whisper UserAction rows out of a user's public activity feed for
  # viewers who are not in the whisper audience. A whisper post is one whose
  # `posts.id` has a `mod_whisper_target_user_ids` post_custom_fields row —
  # key presence marks it, even with an empty `[]` value. The audience rules
  # mirror `GuardianExtensions#can_see_post?` and `WhisperQueryFilter`:
  #
  #   visible = post is not a whisper
  #           OR viewer is staff
  #           OR viewer is the post author
  #           OR viewer id appears in the post's explicit user targets
  #           OR viewer is a member of one of the post's target groups
  #           OR viewer holds one of the post's target badges
  #
  # Anything that doesn't match is filtered. Anonymous viewers never see
  # whispers.
  #
  # `UserAction.stream` returns an Array of UserAction-like rows already
  # joined to posts/topics, so the filter runs in Ruby against the array
  # rather than reshaping the underlying SqlBuilder. This loses an exact
  # page count when a stream page contains whispers (a 30-row page becomes
  # e.g. 28 visible rows), which is acceptable — correctness of visibility
  # outranks pagination precision, and the next-page link still works
  # because the SQL window is unchanged.
  module UserActionWhisperFilter
    module_function

    # Filter `rows` (Array of UserAction-like objects, each responding to
    # `post_id` and `target_topic_id`) for `viewer` (User or nil).
    # Returns a new array containing only rows whose target_post is visible
    # to viewer per the whisper visibility rules above. Falls back to the
    # "hide every whisper" on any error so an upstream Discourse change can
    # neither 500 the /u/{user}/activity page nor leak through it.
    def apply(rows, viewer)
      return rows if rows.blank?
      return rows if viewer&.admin?

      post_ids = rows.map { |r| r.respond_to?(:post_id) ? r.post_id : nil }.compact.uniq
      return rows if post_ids.empty?

      blocked_post_ids = blocked_whisper_post_ids(post_ids, viewer)
      return rows if blocked_post_ids.empty?

      rows.reject do |r|
        pid = r.respond_to?(:post_id) ? r.post_id : nil
        pid && blocked_post_ids.include?(pid)
      end
    rescue StandardError => e
      # Fail CLOSED: if the precise filter breaks, hide every whisper row
      # rather than showing them all.
      ::Rails.logger.warn(
        "[jtech-tools] UserActionWhisperFilter fell back: #{e.class}: #{e.message}",
      )
      begin
        whisper_ids = DiscourseModCategories::Whisper.whisper_post_ids(post_ids || []).to_set
        rows.reject { |r| r.respond_to?(:post_id) && whisper_ids.include?(r.post_id) }
      rescue StandardError
        # Can't even tell which rows are whispers: show no post rows at all.
        rows.reject { |r| r.respond_to?(:post_id) && r.post_id }
      end
    end

    # Of `post_ids`, return the subset that are whispers NOT visible to
    # `viewer`.
    def blocked_whisper_post_ids(post_ids, viewer)
      DiscourseModCategories::Whisper.hidden_post_ids(post_ids, viewer)
    end
  end
end
