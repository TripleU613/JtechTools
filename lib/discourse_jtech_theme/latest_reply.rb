# frozen_string_literal: true

module DiscourseJtechTheme
  # The newest reply the viewer can read, for each topic of a topic list, so
  # the JTech theme's cards can show it under the title instead of the first
  # post (setting jtech_topic_list_latest_reply). One query per list.
  #
  # "Can read" is core's post stream rules: regular posts only (no small
  # actions, no core whispers), not hidden or deleted, no one the viewer
  # ignores, and the plugin's whispers only for their audience. A topic using
  # discourse-private-replies is left out for everyone but staff: that plugin
  # decides per viewer in ways a list query can't follow.
  module LatestReply
    module_function

    def enabled?
      DiscourseJtechTheme.enabled? && SiteSetting.jtech_topic_list_latest_reply
    end

    def preload!(topics, user)
      topics = topics.select { |t| t.highest_post_number.to_i > 1 }
      return if topics.empty?

      user = nil unless user.is_a?(::User)
      topic_ids = topics.map(&:id) - private_reply_topic_ids(topics, user)
      return if topic_ids.empty?

      posts = latest_posts(topic_ids, user)
      users = ::User.where(id: posts.map(&:user_id)).index_by(&:id)

      by_topic = posts.index_by(&:topic_id)
      topics.each do |topic|
        post = by_topic[topic.id]
        author = post && users[post.user_id]
        topic.jt_latest_reply = post && author && serialize(post, author)
      end
    end

    def latest_posts(topic_ids, user)
      scope =
        ::Post
          .select("DISTINCT ON (posts.topic_id) posts.*")
          .where(topic_id: topic_ids, post_type: ::Post.types[:regular], hidden: false)
          .where("posts.post_number > 1")
          .where(user_deleted: false)
          .order("posts.topic_id, posts.post_number DESC")

      if user
        ignored = ::IgnoredUser.where(user_id: user.id).select(:ignored_user_id)
        scope = scope.where.not(user_id: ignored)
      end

      if defined?(::DiscourseModCategories::WhisperQueryFilter)
        scope = ::DiscourseModCategories::WhisperQueryFilter.apply(scope, user)
      end

      scope.to_a
    end

    def private_reply_topic_ids(topics, user)
      return [] unless SiteSetting.respond_to?(:private_replies_enabled)
      return [] unless SiteSetting.private_replies_enabled
      return [] if user&.staff?

      ::TopicCustomField
        .where(topic_id: topics.map(&:id), name: "private_replies")
        .where("value IN ('t', 'true')")
        .pluck(:topic_id)
    end

    # Excerpts are cached by the post's edit, so a list doesn't re-render the
    # same replies on every load.
    def serialize(post, author)
      excerpt =
        Discourse
          .cache
          .fetch("jt-latest-reply:v3:#{post.id}:#{post.updated_at.to_i}", expires_in: 1.day) do
            ::Post.excerpt(
              without_emoji(post.cooked),
              SiteSetting.topic_excerpt_maxlength,
              strip_links: true,
              strip_images: true,
              text_entities: true,
              post: post,
            ).squish
          end

      {
        post_number: post.post_number,
        excerpt: excerpt,
        created_at: post.created_at,
        username: author.username,
        name: author.name,
        avatar_template: author.avatar_template,
      }
    end

    # Core's excerpt writes an emoji out as its code (":smile:"), which reads
    # as noise in a one-line preview; the card leaves emoji out instead. Not
    # every emoji is an image in the cooked post: with emoji turned off, or in
    # a code span, it stays the character or the code the author typed.
    def without_emoji(cooked)
      return cooked if cooked.blank?

      doc = Nokogiri::HTML5.fragment(cooked)
      doc.css("img.emoji").each(&:remove)
      doc
        .xpath(".//text()")
        .each do |node|
          text = without_text_emoji(node.content)
          node.content = text if text != node.content
        end
      doc.to_html
    end

    def without_text_emoji(text)
      text = text.gsub(unicode_emoji_regexp, "") if !text.ascii_only?
      text.gsub(::Emoji::EMOJI_CODE_REGEXP) { |code| ::Emoji.exists?($1) ? "" : code }
    end

    # Core's own list of emoji characters (the ones it would draw as images),
    # longest first so a sequence isn't cut into its parts.
    def unicode_emoji_regexp
      @unicode_emoji_regexp ||=
        begin
          union = Regexp.union(::Emoji.unicode_replacements.keys.sort_by { |k| -k.length })
          Regexp.new("(?:#{union.source})\\u{FE0F}?")
        end
    end
  end
end
