# frozen_string_literal: true

module DiscourseDisteleplus
  # Forum post → Telegram summary, the one feature worth borrowing from
  # discourse-chat-integration: "user posted in <topic>" plus an excerpt, sent
  # into the conversation topic of the bridged group and mirrored into the
  # native conversation as a bot message. Filtered by category, tag, and
  # optionally first posts only. Uses the same visibility rules as the
  # forum-upload archive so private content never leaks.
  module ForumPostNotifier
    def self.enabled?
      DiscourseDisteleplus.enabled? && SiteSetting.disteleplus_forum_post_notifications_enabled
    end

    def self.eligible?(post)
      return false unless enabled?
      return false if post.nil? || post.deleted_at.present? || post.hidden?
      return false if post.post_type != Post.types[:regular]
      # Whispers are private to their audience — never announced.
      return false if DiscourseModCategories::Whisper.whisper?(post)
      return false if post.user.nil? || post.user.bot?

      topic = post.topic
      return false if topic.nil? || topic.private_message? || topic.archetype != Archetype.default
      return false if topic.category.nil? || topic.category.read_restricted
      return false if SiteSetting.disteleplus_forum_post_first_post_only && !post.is_first_post?

      categories = SiteSetting.disteleplus_forum_post_categories_map.reject(&:zero?)
      if categories.any?
        ids = [topic.category_id, topic.category.parent_category_id].compact
        return false if (ids & categories).empty?
      end

      tags = SiteSetting.disteleplus_forum_post_tags_map.map(&:downcase).compact_blank
      if tags.any?
        topic_tags = topic.tags.pluck(:name).map(&:downcase)
        return false if (topic_tags & tags).empty?
      end

      true
    end

    def self.excerpt(post)
      return "" if SiteSetting.disteleplus_forum_post_excerpt_length.to_i <= 0
      post.excerpt(
        SiteSetting.disteleplus_forum_post_excerpt_length,
        text_entities: true,
        strip_links: true,
        remap_emoji: true,
      ).to_s
    end

    def self.telegram_html(post)
      title = Formatter.escape_html(post.topic.title)
      user = Formatter.escape_html(post.user.name.presence || post.user.username)
      body = Formatter.escape_html(excerpt(post))
      verb = post.is_first_post? ? "posted" : "replied in"
      text = "<b>#{user}</b> #{verb} <a href=\"#{post.full_url}\">#{title}</a>"
      text += "\n\n<blockquote>#{body}</blockquote>" if body.present?
      text
    end

    def self.native_markdown(post)
      user = post.user.username
      verb = post.is_first_post? ? "posted" : "replied in"
      body = excerpt(post)
      text = "**@#{user}** #{verb} [#{post.topic.title}](#{post.full_url})"
      text += "\n> #{body.gsub("\n", "\n> ")}" if body.present?
      text
    end
  end
end
