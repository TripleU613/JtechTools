# frozen_string_literal: true

module DiscourseDisteleplus
  # One policy shared by the historical scan and live delivery. Keeping the
  # decision here prevents a future backfill from exposing material that the
  # live hook would have rejected (or vice versa).
  module ForumUploadPolicy
    def self.eligible?(post)
      return false if post.nil? || post.deleted_at.present? || post.hidden?
      return false unless post.post_type == ::Post.types[:regular]
      # A whisper's attachments are as private as its text.
      return false if DiscourseModCategories::Whisper.whisper?(post)

      topic = post.topic
      return false if topic.nil? || topic.deleted_at.present? || !topic.visible?
      return false unless topic.archetype == Archetype.default

      category_ids = SiteSetting.disteleplus_forum_upload_category_ids_map.reject(&:zero?)
      return false if category_ids.present? && category_ids.exclude?(topic.category_id)

      if !SiteSetting.disteleplus_forum_upload_include_restricted_categories &&
           topic.read_restricted_category?
        return false
      end

      true
    end

    def self.eligible_scope
      scope =
        ::Post
          .joins(:topic)
          .where(deleted_at: nil, hidden: false, post_type: ::Post.types[:regular])
          .where(topics: { deleted_at: nil, visible: true, archetype: Archetype.default })
          .where("NOT #{DiscourseModCategories::WhisperQueryFilter.is_whisper_sql("posts")}")

      category_ids = SiteSetting.disteleplus_forum_upload_category_ids_map.reject(&:zero?)
      scope = scope.where(topics: { category_id: category_ids }) if category_ids.present?

      unless SiteSetting.disteleplus_forum_upload_include_restricted_categories
        scope = scope.joins("LEFT JOIN categories ON categories.id = topics.category_id")
        scope = scope.where("categories.id IS NULL OR categories.read_restricted = false")
      end

      scope
    end
  end
end
