# frozen_string_literal: true

module DiscourseDiscordMirror
  # What may leave the forum. Discord is public to anyone in the server, so
  # the test is "could a logged-out visitor read this on the forum right
  # now", plus the cases where core shows a guest something we still keep
  # home (hidden posts, unlisted topics, whispers, staff notes).
  module Visibility
    module_function

    def anon_guardian
      Guardian.new(nil)
    end

    def category?(category)
      return false if category.nil?
      return false if category.id == SiteSetting.uncategorized_category_id
      return false if excluded?(category)
      anon_guardian.can_see_category?(category)
    end

    def excluded?(category)
      ids = SiteSetting.discord_mirror_excluded_categories_map
      ids.include?(category.id) || ids.include?(category.parent_category_id)
    end

    def topic?(topic)
      return false if topic.nil? || topic.deleted_at.present?
      return false if topic.archetype != Archetype.default
      return false unless topic.visible
      # A category's "About" topic is the forum's own furniture.
      return false if Category.exists?(topic_id: topic.id)
      return false unless category?(topic.category)
      anon_guardian.can_see_topic?(topic)
    end

    # `topic_checked:` skips the topic half when the caller already checked
    # it, so a topic's posts don't repeat the same queries.
    def post?(post, topic: post&.topic, topic_checked: false)
      return false if post.nil? || post.deleted_at.present? || post.hidden?
      return false if post.post_type != Post.types[:regular]
      return false if post.user.nil?
      return false if DiscourseModCategories::Whisper.whisper?(post)
      return false unless topic_checked || topic?(topic)
      anon_guardian.can_see_post?(post)
    end
  end
end
