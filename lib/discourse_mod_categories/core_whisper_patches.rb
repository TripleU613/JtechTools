# frozen_string_literal: true

module DiscourseModCategories
  # Plugin whispers are regular posts (post_type 1), so every core code path
  # that special-cases core whispers with `post.whisper?` or the post-type
  # SQL would otherwise treat them as public. These prepends make core treat
  # them as whispers wherever that only ever HIDES more:
  #
  #   * Post#whisper? — PostCreator then skips bumping the topic, updating
  #     last_posted_at / last_poster / word count and user last_posted_at;
  #     TopicLink skips extracting the post's links into the public topic
  #     map; the tracking-state job skips the /latest broadcast; PM tracking
  #     narrows its broadcast to staff; PostDestroyer skips re-bumping.
  #   * Topic.public_post_types_sql — Topic.reset_highest (post delete /
  #     recover / move) recomputes highest_post_number, posts_count,
  #     last_posted_at and last_post_user_id from public posts only.
  #   * Post#publish_message! — every /topic/:id MessageBus message about a
  #     whisper (created, revised, liked, deleted…) goes to its audience only,
  #     and the topic stats broadcast is skipped.
  #   * Post#create_reply_relationship_with — a whisper reply doesn't raise
  #     its parent's public reply_count.
  #   * Topic#reset_bumped_at — the bump goes back to the last public post,
  #     never a whisper.
  module PostWhisperPatch
    def whisper?
      super || DiscourseModCategories::Whisper.whisper?(self)
    end

    # Whisper.prime! remembers a post's whisper fields; changing or
    # reloading the post forgets them.
    def save_custom_fields(*)
      DiscourseModCategories::Whisper.forget!(self)
      super
    end

    def reload(*)
      DiscourseModCategories::Whisper.forget!(self)
      super
    end

    def publish_change_to_clients!(type, opts = {})
      opts = opts.merge(skip_topic_stats: true) if DiscourseModCategories::Whisper.whisper?(self)
      super(type, opts)
    end

    def publish_message!(channel, message, opts = {})
      audience = DiscourseModCategories::Whisper.audience_user_ids(self)
      return super if audience.nil?
      return unless topic

      user_ids = ::User.human_users.where(id: audience).pluck(:id)
      return if user_ids.empty?

      ::MessageBus.publish(channel, message, opts.except(:group_ids).merge(user_ids: user_ids))
    end

    def create_reply_relationship_with(post)
      return super unless DiscourseModCategories::Whisper.whisper?(self)
      return if post.nil? || deleted_at.present?

      post.post_replies.new(reply_post_id: id).save
    end
  end

  # Whisper-ness of a new post is decided the moment PostCreator builds it,
  # on every path — :before_create_post is skipped by core whenever
  # skip_validations is set (approving a queued post among others).
  module PostCreatorWhisperPatch
    private

    def setup_post
      result = super
      DiscourseModCategories::Whisper.prepare_new_post!(@post, @opts) if @post
      result
    end
  end

  # Class-level Post scopes core uses as its "posts this viewer may see"
  # filters. Post.secured(guardian) backs /posts/:id/replies, reply history,
  # PostAlerter's collapsed "N replies" counts, bookmarks, drafts, the user
  # summary, the review scope and more; Post.for_mailing_list backs the
  # digest's popular posts and mailing-list mode.
  module PostClassWhisperPatch
    def secured(guardian)
      DiscourseModCategories::WhisperQueryFilter.apply(super, guardian&.user)
    end

    def for_mailing_list(user, since)
      DiscourseModCategories::WhisperQueryFilter.apply(super, user)
    end
  end

  # "Previous replies" context in notification e-mails.
  module UserNotificationsWhisperPatch
    def get_context_posts(post, topic_user, user)
      result = super
      if result.is_a?(::ActiveRecord::Relation)
        DiscourseModCategories::WhisperQueryFilter.apply(result, user)
      else
        DiscourseModCategories::Whisper.reject_hidden(result, user)
      end
    end
  end

  # A link to a whisper, on its own line in any post, would be expanded into
  # a quote/card carrying the whisper's excerpt and author — and that HTML is
  # baked into the LINKING post's cooked content, which everyone reading that
  # post sees (the /onebox preview endpoint returns the same HTML to any
  # signed-in user). Whispers are never oneboxed; the link stays a link.
  module OneboxerWhisperPatch
    def local_topic_html(url, route, opts)
      return nil if DiscourseModCategories::Whisper.onebox_target_whisper?(route)
      super
    end
  end

  module TopicClassWhisperPatch
    def public_post_types_sql
      "(#{super} AND NOT #{DiscourseModCategories::WhisperQueryFilter.is_whisper_sql("posts")})"
    end
  end

  # Topic#reset_bumped_at (the last public post deleted or hidden by flags,
  # "reset bump date") moves the bump to the topic's last regular post, which
  # can be a whisper: the topic jumped up the list for everyone over a post
  # most of them can't see. The last post that isn't a whisper sets it, and a
  # whisper staff pick to reset the bump to hands it to the post before it.
  module TopicWhisperPatch
    def reset_bumped_at(post_or_post_id = nil)
      if !post_or_post_id
        return super(DiscourseModCategories::Whisper.last_bumping_post(self) || first_post)
      end

      post = post_or_post_id.is_a?(::Post) ? post_or_post_id : ::Post.find_by(id: post_or_post_id)
      if post && DiscourseModCategories::Whisper.whisper?(post)
        return(
          super(DiscourseModCategories::Whisper.last_bumping_post(self, before: post) || first_post)
        )
      end
      super
    end
  end

  # /posts.json, /posts.rss, /private-posts (and the MCP "latest posts" tool).
  module LatestPostsQueryWhisperPatch
    def public_posts(before_post_id: nil)
      DiscourseModCategories::WhisperQueryFilter.apply(super, @user)
    end

    def private_posts(before_post_id: nil)
      DiscourseModCategories::WhisperQueryFilter.apply(super, @user)
    end
  end

  module GuardianWhisperScopePatch
    # Group activity posts/mentions (JSON + RSS), PostsFilter, nested topics
    # and several bundled plugins funnel their post relations through here.
    def filter_hidden_posts(records, category: nil, category_id_column: "topics.category_id")
      DiscourseModCategories::WhisperQueryFilter.apply(super, authenticated? ? @user : nil)
    end
  end

  # Group-SMTP PMs e-mail every post to all participants and CC addresses
  # without a Guardian check. A whisper never goes out that way; the normal,
  # Guardian-gated PM notifications take over.
  module PostAlerterWhisperPatch
    def group_notifying_via_smtp(post)
      return nil if DiscourseModCategories::Whisper.whisper?(post)
      super
    end
  end

  # Moving posts bumps the destination topic when its last post is one of
  # the moved ones, and makes that post the topic's last post. Core skips
  # only core whispers when it picks that post, so a moved whisper bumped
  # the topic for everyone and showed its author as the last poster. The
  # scope narrows core's query to skip ours too; all_queries is what
  # reaches the destination.ordered_posts association.
  #
  # With "keep the original" core copies each reply with Post#dup, which
  # leaves custom fields behind, so a whisper's copy came out public; the
  # copies take the whisper fields once every post is moved, before anything
  # else reads them. Core also counts each moved reply towards the moved
  # post it answers, so a moved whisper added a reply to a public post.
  module PostMoverWhisperPatch
    private

    def move_each_post
      super
      DiscourseModCategories::Whisper.copy_to_moved_copies!
      whisper_ids = DiscourseModCategories::Whisper.whisper_post_ids(@post_ids_after_move)
      if whisper_ids.any?
        DiscourseModCategories::Whisper.posts_moved!(destination_topic, whisper_ids)
      end
    end

    def update_last_post_stats
      ::Post
        .where("NOT #{DiscourseModCategories::WhisperQueryFilter.is_whisper_sql("posts")}")
        .scoping(all_queries: true) { super }
    end
  end

  # Topic "participants" (avatars + counts in the topic map) are computed
  # with raw SQL over every post.
  module TopicViewWhisperPatch
    def post_counts_by_user
      @post_counts_by_user ||=
        if is_mega_topic?
          {}
        else
          scope =
            ::Post
              .where(
                topic_id: @topic.id,
                post_type: ::Topic.visible_post_types(@guardian&.user),
                action_code: nil,
              )
              .where.not(user_id: nil)
          DiscourseModCategories::WhisperQueryFilter
            .apply(scope, @guardian&.user)
            .group(:user_id)
            .order(::Arel.sql("COUNT(*) DESC"))
            .limit(::TopicView::MAX_PARTICIPANTS)
            .count
        end
    end

    def participant_count
      @participant_count ||=
        if participants.size == ::TopicView::MAX_PARTICIPANTS &&
             @topic.posts_count <= ::TopicView::MAX_POSTS_COUNT_PARTICIPANTS
          DiscourseModCategories::WhisperQueryFilter
            .apply(::Post.where(topic_id: @topic.id).where.not(user_id: nil), @guardian&.user)
            .distinct
            .count(:user_id)
        else
          super
        end
    end
  end

  # /u/:username/summary — top replies, links, categories, replied-to users.
  module UserSummaryWhisperPatch
    def post_query
      DiscourseModCategories::WhisperQueryFilter.apply(super, @guardian&.user)
    end
  end

  # Activity-feed stats and stream, filtered in SQL (exact pagination and
  # per-type counts). The Ruby post-filter on UserAction.stream stays as a
  # second layer.
  module UserActionClassWhisperPatch
    def apply_common_filters(builder, user_id, guardian, ignore_private_messages = false)
      super
      viewer = guardian&.user
      viewer = nil unless viewer.is_a?(::User) && viewer.id
      sql = DiscourseModCategories::WhisperQueryFilter.predicate(viewer, "p")
      return if sql.nil?

      if viewer
        builder.where("p.id IS NULL OR #{sql}", mw_uid: viewer.id)
      else
        builder.where("p.id IS NULL OR #{sql}")
      end
    end
  end

  # Featured posters (topic-list avatars) and participant_count are rebuilt
  # with raw SQL that counts every regular post. Afterwards, drop anyone
  # whose only posts in the topic are whispers.
  module TopicFeaturedUsersClassWhisperPatch
    def ensure_consistency!(topic_id = nil)
      super
      DiscourseModCategories::Whisper.scrub_featured_users(topic_id)
    end
  end

  module TopicFeaturedUsersWhisperPatch
    def update_participant_count
      super
      DiscourseModCategories::Whisper.scrub_featured_users(topic.id)
    end
  end

  # Badges earned by a whisper show the post (number, topic, link) on the
  # user's badge page. Only to people who can see it.
  module UserBadgePostAttributesWhisperPatch
    private

    def include_post_attributes?
      return false unless super
      post = object.post
      post.nil? || DiscourseModCategories::Whisper.visible_to?(post, scope&.user)
    end
  end

  # "quote-modified" / "quote-post-not-found" CSS on a quote would let
  # anyone test guesses about a whisper's text. Whispers are never compared.
  module QuoteComparerWhisperPatch
    def missing?
      return false if @parent_post && DiscourseModCategories::Whisper.whisper?(@parent_post)
      super
    end

    def modified?
      return false if @parent_post && DiscourseModCategories::Whisper.whisper?(@parent_post)
      super
    end
  end

  # A public post that replies to a whisper must not show the whisper's
  # author ("in reply to @someone") to people who can't see the whisper.
  module PostSerializerWhisperPatch
    def include_reply_to_user?
      return false unless super
      number = object.reply_to_post_number
      return true if number.blank?

      # One query per topic (memoized on the topic object the stream's posts
      # share), then a lookup only for replies that answer a whisper.
      topic = object.topic
      numbers =
        if topic
          topic.instance_variable_get(:@mod_whisper_post_numbers) ||
            topic.instance_variable_set(
              :@mod_whisper_post_numbers,
              DiscourseModCategories::Whisper.whisper_post_numbers(topic.id).to_set,
            )
        else
          DiscourseModCategories::Whisper.whisper_post_numbers(object.topic_id).to_set
        end
      return true if numbers.exclude?(number)

      replied = ::Post.find_by(topic_id: object.topic_id, post_number: number)
      replied.nil? || DiscourseModCategories::Whisper.visible_to?(replied, scope&.user)
    end
  end

  # Queued posts that will become whispers are only shown to staff in the
  # review queue (category-group moderators are not in a whisper's audience).
  # Flagged whispers are already excluded through reviewable_post_scope,
  # which is built on Post.secured.
  module ReviewableClassWhisperPatch
    def viewable_by(user, order: nil, preload: true)
      result = super
      # ponytail: moderators included, so a non-staff reply to an admin's
      # whisper that waits for approval shows in their queue until approved
      # (the queued post can't carry the admins-only mark yet); check the
      # payload's reply target here if that matters.
      return result if user.nil? || user.staff?

      result.where(<<~SQL)
        NOT (
          reviewables.type = 'ReviewableQueuedPost'
          AND COALESCE(reviewables.payload->>'#{DiscourseModCategories::POST_WHISPER_ARMED_PARAM}', '') = 'true'
        )
      SQL
    end
  end

  # AI topic summaries / gists are cached per topic and shown to everyone who
  # can read the topic, so they must be built from public posts only.
  module AiSummaryTargetsWhisperPatch
    def targets_data
      data = super
      return data unless target.is_a?(::Topic)
      hidden = DiscourseModCategories::Whisper.whisper_post_numbers(target.id)
      return data if hidden.empty?
      data.reject { |item| hidden.include?(item[:id]) }
    end
  end

  # AI topic embeddings (semantic search ranking) are built from the topic's
  # posts; leave whispers out.
  module AiTopicTruncationWhisperPatch
    def topic_truncation(topic, tokenizer, max_length)
      return super if DiscourseModCategories::Whisper.whisper_post_numbers(topic&.id).empty?

      text = +topic_information(topic)
      if topic&.topic_embed&.embed_content_cache.present?
        text << Nokogiri::HTML5.fragment(topic.topic_embed.embed_content_cache).text
        text << " "
      end

      posts_text = +""
      posts_text_size = 0
      ratio = self.class::TEXT_TO_HTML_TOKEN_RATIO
      DiscourseModCategories::WhisperQueryFilter
        .apply(topic.posts, nil)
        .find_each do |post|
          posts_text_size += tokenizer.size(post.cooked)
          posts_text << post.cooked
          posts_text << " "
          break if posts_text_size >= max_length * ratio
        end

      text << Nokogiri::HTML5.fragment(posts_text).text
      tokenizer.truncate(text, max_length, strict: SiteSetting.ai_strict_token_counting)
    end

    def post_truncation(post, tokenizer, max_length)
      return "" if DiscourseModCategories::Whisper.whisper?(post)
      super
    end
  end

  # discourse-chat-integration forwards new posts to Slack/Discord/Teams/…
  # after checking visibility as its bot user — by default the system user,
  # an admin, who can see every whisper. A whisper never leaves the forum.
  module ChatIntegrationWhisperPatch
    def trigger_notifications(post_id)
      post = ::Post.find_by(id: post_id)
      return if post && DiscourseModCategories::Whisper.whisper?(post)
      super
    end
  end

  # Nested-replies view (/n/...) builds its own post queries; every batch of
  # posts it renders is loaded through load_posts_for_tree.
  module NestedTreeLoaderWhisperPatch
    def load_posts_for_tree(scope)
      DiscourseModCategories::WhisperQueryFilter.apply(super, guardian&.user)
    end

    def apply_visibility(scope, posts_table: "posts")
      DiscourseModCategories::WhisperQueryFilter.apply(
        super,
        guardian&.user,
        posts_table: posts_table,
      )
    end
  end

  def self.apply_core_whisper_patches!
    ::Post.prepend(PostWhisperPatch)
    ::PostCreator.prepend(PostCreatorWhisperPatch)
    ::Post.singleton_class.prepend(PostClassWhisperPatch)
    ::Topic.singleton_class.prepend(TopicClassWhisperPatch)
    ::Topic.prepend(TopicWhisperPatch)
    ::Oneboxer.singleton_class.prepend(OneboxerWhisperPatch)
    ::UserNotifications.singleton_class.prepend(UserNotificationsWhisperPatch)
    ::LatestPostsQuery.prepend(LatestPostsQueryWhisperPatch)
    ::Guardian.prepend(GuardianWhisperScopePatch)
    ::PostAlerter.prepend(PostAlerterWhisperPatch)
    ::PostMover.prepend(PostMoverWhisperPatch)
    ::TopicView.prepend(TopicViewWhisperPatch)
    ::UserSummary.prepend(UserSummaryWhisperPatch)
    ::UserAction.singleton_class.prepend(UserActionClassWhisperPatch)
    ::TopicFeaturedUsers.singleton_class.prepend(TopicFeaturedUsersClassWhisperPatch)
    ::TopicFeaturedUsers.prepend(TopicFeaturedUsersWhisperPatch)
    ::UserBadgePostAndTopicAttributesMixin.prepend(UserBadgePostAttributesWhisperPatch)
    ::QuoteComparer.prepend(QuoteComparerWhisperPatch)
    ::PostSerializer.prepend(PostSerializerWhisperPatch)
    ::Reviewable.singleton_class.prepend(ReviewableClassWhisperPatch)

    if defined?(::DiscourseChatIntegration::Manager)
      ::DiscourseChatIntegration::Manager.singleton_class.prepend(ChatIntegrationWhisperPatch)
    end
    if defined?(::NestedReplies::TreeLoader)
      ::NestedReplies::TreeLoader.prepend(NestedTreeLoaderWhisperPatch)
    end
    if defined?(::DiscourseAi::Summarization::Strategies::TopicSummary)
      ::DiscourseAi::Summarization::Strategies::TopicSummary.prepend(AiSummaryTargetsWhisperPatch)
    end
    if defined?(::DiscourseAi::Summarization::Strategies::HotTopicGists)
      ::DiscourseAi::Summarization::Strategies::HotTopicGists.prepend(AiSummaryTargetsWhisperPatch)
    end
    if defined?(::DiscourseAi::Embeddings::Strategies::Truncation)
      ::DiscourseAi::Embeddings::Strategies::Truncation.prepend(AiTopicTruncationWhisperPatch)
    end
  end
end
