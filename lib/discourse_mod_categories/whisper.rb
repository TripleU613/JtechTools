# frozen_string_literal: true

module DiscourseModCategories
  # Single source of truth for "who may see this whisper".
  #
  # A whisper is a regular post that carries a POST_WHISPER_TARGETS_FIELD
  # custom-field row (KEY PRESENCE marks it, even an empty `[]`). Its
  # audience is exactly:
  #
  #   * every admin, and every moderator unless an admin wrote it (or it
  #     answers one an admin wrote): then moderators only as targets
  #   * the post's author
  #   * the post's explicit target users
  #   * current members of the post's target groups
  #   * current holders of the post's target badges
  #
  # Nobody else — in particular NOT "everyone who was ever whispered to in
  # this topic". The audience of a whisper is what its banner says it is.
  #
  # Visibility is enforced unconditionally: it does not depend on
  # mod_whisper_enabled, jtech_enabled or any other toggle. Switching the
  # feature off stops NEW whispers from being created; it must never turn
  # existing private text public. The only way to publish a whisper is the
  # explicit staff "convert to public" action.
  #
  # Every read path (Guardian, the topic-stream SQL filter, search, the
  # activity feed, notifications, e-mail, live updates, …) goes through the
  # helpers here so the rules can never drift apart.
  module Whisper
    module_function

    def targets_field
      DiscourseModCategories::POST_WHISPER_TARGETS_FIELD
    end

    def groups_field
      DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD
    end

    def badges_field
      DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD
    end

    def admins_only_field
      DiscourseModCategories::POST_WHISPER_ADMINS_ONLY_FIELD
    end

    def whisper_fields
      [targets_field, groups_field, badges_field, admins_only_field]
    end

    # An admin's whisper: moderators see it only as its targets
    def admins_only?(post)
      post.is_a?(::Post) && post_fields(post).key?(admins_only_field)
    end

    # Whisper audience definition for `post`, or nil when the post is not a
    # whisper. Reads the in-memory custom fields when they are a plain Hash
    # (the normal, lazily-loaded case) and falls back to the database when
    # the post carries a preloaded proxy that may not include our keys — a
    # NotPreloadedError must never be the reason a whisper renders.
    def data(post)
      return nil unless post.is_a?(::Post)

      fields = post_fields(post)
      return nil unless fields.key?(targets_field)

      {
        user_ids: normalize_ids(fields[targets_field]),
        group_ids: normalize_ids(fields[groups_field]),
        badge_ids: normalize_ids(fields[badges_field]),
      }
    end

    def whisper?(post)
      !data(post).nil?
    end

    # True when `user` (a User or nil) may see `post`. Non-whispers are
    # always "visible" as far as whisper rules go — the caller's normal
    # Guardian checks still apply on top.
    def visible_to?(post, user)
      d = data(post)
      return true if d.nil?
      audience_member?(post, d, user)
    end

    def audience_member?(post, d, user)
      return false unless user.is_a?(::User) && user.id
      return true if user.admin?
      return true if user.moderator? && !admins_only?(post)
      return true if post.user_id.present? && post.user_id == user.id
      return true if d[:user_ids].include?(user.id)
      # Core memoizes the user's group ids, so the many Guardian checks a
      # post's serializer makes don't each query them.
      return true if d[:group_ids].intersect?(user.belonging_to_group_ids)
      if d[:badge_ids].any? && ::UserBadge.exists?(badge_id: d[:badge_ids], user_id: user.id)
        return true
      end
      false
    end

    # All user ids in the whisper's audience (staff included unless
    # `include_staff: false`). Used to narrow notification / broadcast
    # recipient lists. Returns nil for a non-whisper.
    def audience_user_ids(post, include_staff: true)
      d = data(post)
      return nil if d.nil?

      ids = []
      ids.concat(admins_only?(post) ? admin_user_ids : staff_user_ids) if include_staff
      ids << post.user_id if post.user_id
      ids.concat(::User.where(id: d[:user_ids]).pluck(:id)) if d[:user_ids].any?
      ids.concat(::GroupUser.where(group_id: d[:group_ids]).pluck(:user_id)) if d[:group_ids].any?
      ids.concat(::UserBadge.where(badge_id: d[:badge_ids]).pluck(:user_id)) if d[:badge_ids].any?
      ids.compact.uniq.select { |id| id > 0 }
    end

    def staff_user_ids
      ::User.where("admin OR moderator").pluck(:id)
    end

    def admin_user_ids
      ::User.where(admin: true).pluck(:id)
    end

    # Of `post_ids`, the subset that are whispers `user` may NOT see. One
    # query to find the whispers, one to narrow them with the SQL filter.
    def hidden_post_ids(post_ids, user)
      user = nil unless user.is_a?(::User)
      post_ids = Array(post_ids).compact.uniq
      return [] if post_ids.empty?
      return [] if user&.admin?

      whisper_ids = whisper_post_ids(post_ids)
      return [] if whisper_ids.empty?
      return whisper_ids if user.nil?

      visible = WhisperQueryFilter.apply(::Post.unscoped.where(id: whisper_ids), user).pluck(:id)
      whisper_ids - visible
    end

    def whisper_post_ids(post_ids)
      ::PostCustomField.where(post_id: post_ids, name: targets_field).distinct.pluck(:post_id)
    end

    # Drop hidden whispers from an Array of posts (or post-like rows that
    # respond to `id`/`post_id`), preserving order.
    def reject_hidden(records, user, id_method: :id)
      user = nil unless user.is_a?(::User)
      records = Array(records)
      return records if records.empty? || user&.admin?
      ids = records.map { |r| r.respond_to?(id_method) ? r.public_send(id_method) : nil }.compact
      hidden = hidden_post_ids(ids, user).to_set
      return records if hidden.empty?
      records.reject { |r| r.respond_to?(id_method) && hidden.include?(r.public_send(id_method)) }
    end

    QUOTE_REGEX = /\[quote=[^\]]*\]/i

    # The fields answered_whispers reads, for a post that doesn't exist yet
    # (NewPostManager runs before PostCreator builds one).
    PostStub = Struct.new(:topic_id, :reply_to_post_number, :raw)

    # The whispers a post-being-created answers: the post it replies to and
    # any post it quotes, restricted to whispers the author can actually see.
    # As a side effect, a reply pointer at a whisper the author can NOT see
    # is dropped, so a public post never advertises a hidden whisper through
    # "in reply to".
    def answered_whispers(post, opts, author)
      found = []

      reply_number = (opts[:reply_to_post_number].presence || post.reply_to_post_number).to_i
      if reply_number > 0 && post.topic_id
        replied = ::Post.find_by(topic_id: post.topic_id, post_number: reply_number)
        if replied && whisper?(replied)
          if visible_to?(replied, author)
            found << replied
          else
            opts[:reply_to_post_number] = nil
            post.reply_to_post_number = nil
          end
        end
      end

      post
        .raw
        .to_s
        .scan(QUOTE_REGEX)
        .each do |tag|
          args = tag.scan(/([a-z]+):\s*(\d+)/i).to_h { |k, v| [k.downcase, v.to_i] }
          next if args["post"].to_i <= 0
          topic_id = args["topic"].presence || post.topic_id
          quoted = ::Post.find_by(topic_id: topic_id, post_number: args["post"])
          found << quoted if quoted && whisper?(quoted) && visible_to?(quoted, author)
        end

      found.uniq(&:id)
    end

    # Decide, BEFORE PostCreator saves the post, whether it is a whisper and
    # who its audience is, so the custom fields are persisted atomically by
    # HasCustomFields' after_save callback.
    #
    #   * Staff arm a whisper explicitly (`mod_whisper=true`) and pick targets.
    #   * Anything that answers a whisper — a reply to it, or a post quoting
    #     it — is itself a whisper to that same audience, whoever writes it and
    #     whichever client they use (the /dumb app has no whisper UI at all).
    #     Only staff can opt out, by sending an explicit `mod_whisper=false`.
    #   * A non-staff whisper is never wider than the whisper it answers; with
    #     nothing to answer it is staff-only.
    #   * A topic's first post can never be a whisper: the title, excerpt and
    #     "new topic" notifications are public by nature.
    def prepare_new_post!(post, opts)
      author = post.user
      topic = post.topic_id ? post.topic : nil
      return unless author

      armed_param =
        DiscourseModCategories::Whisper.opt(opts, DiscourseModCategories::POST_WHISPER_ARMED_PARAM)
      explicitly_armed = ::ActiveModel::Type::Boolean.new.cast(armed_param) == true
      explicitly_disarmed = !armed_param.nil? && armed_param.to_s != "" && !explicitly_armed
      explicitly_armed = false unless SiteSetting.mod_whisper_enabled

      answered = DiscourseModCategories::Whisper.answered_whispers(post, opts, author)

      make_whisper =
        if author.staff?
          explicitly_armed || (answered.any? && !explicitly_disarmed)
        else
          explicitly_armed || answered.any?
        end
      return unless make_whisper

      if topic.nil? || !::Post.where(topic_id: topic.id).exists?
        raise Discourse::InvalidParameters.new(
                I18n.t("discourse_mod_categories.whisper.first_post_not_allowed"),
              )
      end

      user_ids, group_ids, badge_ids =
        if author.staff? && explicitly_armed
          norm = ->(key) do
            DiscourseModCategories::Whisper.normalize_ids(
              DiscourseModCategories::Whisper.opt(opts, key),
            ).first(DiscourseModCategories::MAX_WHISPER_TARGETS)
          end
          badge_ids = norm.call(DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD)
          badge_ids = [] unless SiteSetting.mod_whisper_badge_targeting_enabled
          [
            ::User.where(id: norm.call(DiscourseModCategories::POST_WHISPER_TARGETS_FIELD)).pluck(
              :id,
            ),
            ::Group.where(
              id: norm.call(DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD),
            ).pluck(:id),
            ::Badge.where(id: badge_ids, enabled: true).pluck(:id),
          ]
        else
          audience = DiscourseModCategories::Whisper.inherited_audience(answered, author)
          if audience
            [audience[:user_ids], audience[:group_ids], audience[:badge_ids]]
          else
            [[], [], []]
          end
        end

      post.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD] = user_ids
      post.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD] = group_ids
      post.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD] = badge_ids
      # An admin's own whisper, or one answering an admin's, is the admins'
      if (author.admin? && explicitly_armed) || answered.any? { |w| admins_only?(w) }
        post.custom_fields[DiscourseModCategories::POST_WHISPER_ADMINS_ONLY_FIELD] = true
      end

      # Non-staff who arm a whisper out of nowhere (no whisper to answer, not
      # a participant) still get a private post — never a public one — but
      # don't get to page every staff member with it.
      if !author.staff? && answered.empty? &&
           DiscourseModCategories::Whisper.normalize_ids(
             topic.custom_fields[DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD],
           ).exclude?(author.id)
        post.instance_variable_set(:@mod_whisper_quiet, true)
      end

      # Record explicitly targeted non-staff users as topic participants: they
      # may whisper back to staff in this topic. This grants NO visibility.
      participant_ids = ::User.where(id: user_ids).where(admin: false, moderator: false).pluck(:id)
      if author.staff? && participant_ids.any?
        DiscourseModCategories::Whisper.merge_participants(topic, participant_ids)
      end
    end

    # The audience a post answering `answered` whispers inherits: that of the
    # answered whisper (its targets plus its author). When the answered
    # whispers disagree about their audience, nil — the caller falls back to
    # staff-only, the narrowest audience.
    def inherited_audience(answered, author)
      audiences =
        answered.map do |w|
          d = data(w)
          {
            user_ids:
              (d[:user_ids] + [w.user_id]).compact.uniq.reject { |id| id == author.id }.sort,
            group_ids: d[:group_ids].sort,
            badge_ids: d[:badge_ids].sort,
          }
        end
      audiences.uniq!
      audiences.length == 1 ? audiences.first : nil
    end

    # Who gets the plugin's "whispered to you" notification. Staff-authored:
    # the whisper's non-author audience minus staff at large (staff can see
    # every whisper and would drown otherwise). Non-staff-authored: all staff
    # plus the rest of the audience it inherited.
    def notification_recipient_ids(post)
      d = data(post)
      return [] if d.nil?

      ids = []
      ids.concat(admins_only?(post) ? admin_user_ids : staff_user_ids) unless post.user&.staff?
      ids.concat(::User.where(id: d[:user_ids]).pluck(:id)) if d[:user_ids].any?
      # Not the automatic groups (trust levels, everyone, staff): their
      # members still see the whisper, but a whisper to trust_level_2 rang
      # the bell for hundreds of people.
      if d[:group_ids].any?
        ids.concat(
          ::GroupUser
            .joins(:group)
            .where(group_id: d[:group_ids], groups: { automatic: false })
            .pluck(:user_id),
        )
      end
      ids.concat(::UserBadge.where(badge_id: d[:badge_ids]).pluck(:user_id)) if d[:badge_ids].any?
      ids.compact.uniq - [post.user_id]
    end

    # Adds non-staff users to the topic's recorded whisper participants
    # (people staff whispered to here, who may therefore whisper back to
    # staff). Participation grants NO visibility of any whisper.
    def merge_participants(topic, new_ids)
      field = DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD
      existing = normalize_ids(topic.custom_fields[field])
      merged = (existing + normalize_ids(new_ids)).uniq
      return existing if merged.sort == existing.sort

      topic.custom_fields[field] = merged
      topic.save_custom_fields(true)
      merged
    end

    # Post#dup, core's copy of a reply moved with "keep the original", leaves
    # custom fields behind. The copies a PostMover just made take their
    # originals' whisper rows here, as stored, in one statement. They come
    # from PostMover's temp_moved_posts, this move's mapping only: moved_posts
    # keeps every earlier move too, and would make a copy that staff have
    # since made public a whisper again when it's moved on. A moved topic's
    # first post already has them: core copies its fields.
    def copy_to_moved_copies!
      ::DB.exec(<<~SQL, names: whisper_fields)
        INSERT INTO post_custom_fields (post_id, name, value, created_at, updated_at)
        SELECT mp.new_post_id, pcf.name, pcf.value, NOW(), NOW()
        FROM temp_moved_posts mp
        JOIN post_custom_fields pcf ON pcf.post_id = mp.old_post_id AND pcf.name IN (:names)
        WHERE mp.old_post_id <> mp.new_post_id
          AND NOT EXISTS (
            SELECT 1 FROM post_custom_fields copied
            WHERE copied.post_id = mp.new_post_id AND copied.name = pcf.name
          )
      SQL
    end

    # After the whispers `whisper_ids` (copies included) are moved into
    # `topic`. Core counted each one towards the reply count of the moved
    # post it answers, and a staff whisper makes its non-staff targets
    # participants of the topic it is in, as prepare_new_post! does.
    def posts_moved!(topic, whisper_ids)
      ::DB.exec(<<~SQL, ids: whisper_ids, topic_id: topic.id)
        UPDATE posts parent SET reply_count = GREATEST(0, parent.reply_count - x.replies)
        FROM (
          SELECT reply_to_post_number, COUNT(*) AS replies FROM posts
          WHERE id IN (:ids) AND reply_to_post_number IS NOT NULL
          GROUP BY reply_to_post_number
        ) x
        WHERE parent.topic_id = :topic_id AND parent.post_number = x.reply_to_post_number
      SQL

      staff_whisper_ids =
        ::Post
          .where(id: whisper_ids)
          .joins(:user)
          .where("users.admin OR users.moderator")
          .pluck(:id)
      return if staff_whisper_ids.empty?

      target_ids =
        ::PostCustomField
          .where(post_id: staff_whisper_ids, name: targets_field)
          .pluck(:value)
          .flat_map { |value| normalize_ids(value) }
      participant_ids = ::User.where(id: target_ids, admin: false, moderator: false).pluck(:id)
      merge_participants(topic, participant_ids) if participant_ids.any?
    end

    # SQL fragment (for a query over the bare `posts` table) that is true
    # for posts everyone who can read the topic sees: core's public post
    # types, minus whispers.
    def public_posts_sql
      "posts.post_type NOT IN (#{::Post.types[:small_action]}, #{::Post.types[:whisper]}) " \
        "AND NOT #{WhisperQueryFilter.is_whisper_sql("posts")}"
    end

    # Core counts a whisper as a public reply (it is a regular post): it
    # raises highest_post_number and posts_count. Recompute both from public
    # posts only so the topic list shows non-audience viewers no "+1 unread"
    # and no extra reply. The :listable_topic serializer adds the whisper
    # back into highest_post_number for its audience.
    def refresh_topic_counters(topic)
      topic_id = topic.is_a?(::Topic) ? topic.id : topic.to_i
      ::DB.exec(<<~SQL, topic_id: topic_id)
        UPDATE topics SET
          highest_post_number = GREATEST(COALESCE((
            SELECT MAX(post_number) FROM posts
            WHERE topic_id = :topic_id AND deleted_at IS NULL AND #{public_posts_sql}
          ), 0), 1),
          posts_count = (
            SELECT COUNT(*) FROM posts
            WHERE topic_id = :topic_id AND deleted_at IS NULL AND #{public_posts_sql}
          ),
          last_posted_at = COALESCE((
            SELECT MAX(created_at) FROM posts
            WHERE topic_id = :topic_id AND deleted_at IS NULL AND #{public_posts_sql}
          ), last_posted_at),
          last_post_user_id = COALESCE((
            SELECT user_id FROM posts
            WHERE topic_id = :topic_id AND deleted_at IS NULL AND #{public_posts_sql}
            ORDER BY created_at DESC LIMIT 1
          ), last_post_user_id)
        WHERE id = :topic_id
      SQL
    end

    # The post a topic's bump comes from, picked as core's
    # Topic#reset_bumped_at picks it (the last regular post a flag hasn't
    # hidden and its author hasn't withdrawn) but never a whisper. With
    # `before`, only posts ahead of that one count.
    def last_bumping_post(topic, before: nil)
      scope =
        topic
          .ordered_posts
          .where(user_deleted: false, hidden: false, post_type: ::Post.types[:regular])
          .where("NOT #{WhisperQueryFilter.is_whisper_sql("posts")}")
      scope = scope.where("posts.post_number < ?", before.post_number) if before
      scope.last
    end

    # Public reply_count of the posts `post_ids` — whisper replies excluded.
    def refresh_reply_counts(post_ids)
      post_ids = Array(post_ids).compact.uniq
      return if post_ids.empty?
      ::DB.exec(<<~SQL, ids: post_ids)
        UPDATE posts parent SET reply_count = (
          SELECT COUNT(*) FROM post_replies pr
          JOIN posts ON posts.id = pr.reply_post_id
          WHERE pr.post_id = parent.id
            AND posts.deleted_at IS NULL
            AND #{public_posts_sql}
        )
        WHERE parent.id IN (:ids)
      SQL
    end

    def whisper_post_numbers(topic_id)
      return [] if topic_id.blank?
      ::Post
        .unscoped
        .where(topic_id: topic_id)
        .where(id: ::PostCustomField.where(name: targets_field).select(:post_id))
        .pluck(:post_number)
    end

    # Clears featured-poster slots held only by whisper authors and recounts
    # participant_count from public posts, for one topic (or every topic
    # that contains a whisper).
    def scrub_featured_users(topic_id = nil)
      topic_ids =
        if topic_id
          [topic_id.to_i]
        else
          ::Post
            .unscoped
            .where(id: ::PostCustomField.where(name: targets_field).select(:post_id))
            .distinct
            .pluck(:topic_id)
        end
      return if topic_ids.empty?

      public_by = ->(column) { <<~SQL }
        EXISTS (
          SELECT 1 FROM posts
          WHERE posts.topic_id = t.id AND posts.user_id = t.#{column}
            AND posts.deleted_at IS NULL AND NOT posts.hidden
            AND posts.post_type IN (#{::Post.types.values_at(:regular, :moderator_action, :small_action).join(",")})
            AND NOT #{WhisperQueryFilter.is_whisper_sql("posts")}
        )
      SQL

      topic_ids.each_slice(500) { |ids| ::DB.exec(<<~SQL, ids: ids) }
          UPDATE topics t SET
            featured_user1_id = CASE WHEN #{public_by.call("featured_user1_id")} THEN featured_user1_id END,
            featured_user2_id = CASE WHEN #{public_by.call("featured_user2_id")} THEN featured_user2_id END,
            featured_user3_id = CASE WHEN #{public_by.call("featured_user3_id")} THEN featured_user3_id END,
            featured_user4_id = CASE WHEN #{public_by.call("featured_user4_id")} THEN featured_user4_id END,
            participant_count = (
              SELECT COUNT(DISTINCT posts.user_id) FROM posts
              WHERE posts.topic_id = t.id AND NOT posts.hidden AND posts.deleted_at IS NULL
                AND posts.post_type IN (#{::Post.types.values_at(:regular, :moderator_action, :small_action).join(",")})
                AND NOT #{WhisperQueryFilter.is_whisper_sql("posts")}
            )
          WHERE t.id IN (:ids)
        SQL
    end

    # Whether a review-queue item concerns whisper text: a flagged whisper,
    # or a queued post that will become one once approved (armed, replying
    # to a whisper, or quoting one).
    def private_reviewable?(reviewable)
      target = reviewable.try(:target)
      return whisper?(target) if target.is_a?(::Post)
      return false unless reviewable.is_a?(::ReviewableQueuedPost)

      payload = reviewable.payload.is_a?(Hash) ? reviewable.payload : {}
      armed = payload[DiscourseModCategories::POST_WHISPER_ARMED_PARAM]
      return true if ::ActiveModel::Type::Boolean.new.cast(armed) == true

      topic_id = reviewable.topic_id
      reply_number = payload["reply_to_post_number"].to_i
      if topic_id && reply_number > 0
        replied = ::Post.find_by(topic_id: topic_id, post_number: reply_number)
        return true if replied && whisper?(replied)
      end

      payload["raw"]
        .to_s
        .scan(QUOTE_REGEX)
        .any? do |tag|
          args = tag.scan(/([a-z]+):\s*(\d+)/i).to_h { |k, v| [k.downcase, v.to_i] }
          next false if args["post"].to_i <= 0
          quoted = ::Post.find_by(topic_id: args["topic"] || topic_id, post_number: args["post"])
          quoted.present? && whisper?(quoted)
        end
    rescue StandardError
      true
    end

    # Whether a local topic/post onebox route points at a whisper (mirrors
    # Oneboxer.local_topic_html's post lookup).
    def onebox_target_whisper?(route)
      topic_id = (route[:id] || route[:topic_id]).to_i
      return false if topic_id <= 0
      post_number = route[:post_number].to_i
      post =
        if post_number > 1
          ::Post.find_by(topic_id: topic_id, post_number: post_number)
        else
          ::Post.where(topic_id: topic_id).order(:sort_order, :post_number).first
        end
      post.present? && whisper?(post)
    rescue StandardError
      true
    end

    # Posts whose cooked HTML may embed a preview of `post` (they link to
    # it); rebaking them drops a now-private whisper's excerpt.
    def rebake_linking_posts(post)
      ::Post
        .where(id: ::TopicLink.where(link_post_id: post.id).select(:post_id))
        .where.not(id: post.id)
        .find_each { |p| p.rebake!(priority: :low) }
    end

    # Reads a create option whether the caller used string keys (HTTP params)
    # or symbol keys (PostCreator called from Ruby).
    def opt(opts, key)
      return nil unless opts.respond_to?(:[])
      value = opts[key.to_s]
      value = opts[key.to_sym] if value.nil? &&
        !opts.is_a?(ActiveSupport::HashWithIndifferentAccess)
      value
    end

    def normalize_ids(raw)
      raw = parse_json(raw) if raw.is_a?(String)
      Array(raw)
        .map { |v| v.is_a?(Numeric) || v.is_a?(String) ? v.to_i : 0 }
        .reject { |i| i <= 0 }
        .uniq
    end

    def parse_json(raw)
      JSON.parse(raw)
    rescue StandardError
      []
    end

    # Loads the whisper fields of many posts in one query and remembers them
    # on each post, so the per-post checks that follow (Guardian, the post
    # serializer) don't each query. Used for the posts of a topic page.
    def prime!(posts)
      posts = Array(posts).select { |p| p.is_a?(::Post) && p.id }
      return if posts.empty?

      by_post = Hash.new { |h, k| h[k] = {} }
      ::PostCustomField
        .where(post_id: posts.map(&:id), name: whisper_fields)
        .pluck(:post_id, :name, :value)
        .each { |post_id, name, value| by_post[post_id][name] = parse_json(value) }

      posts.each { |p| p.instance_variable_set(:@mod_whisper_fields, by_post[p.id].freeze) }
    end

    def forget!(post)
      if post.instance_variable_defined?(:@mod_whisper_fields)
        post.remove_instance_variable(:@mod_whisper_fields)
      end
    end

    def post_fields(post)
      if post.instance_variable_defined?(:@mod_whisper_fields)
        return post.instance_variable_get(:@mod_whisper_fields)
      end

      # A preloaded proxy only knows the keys somebody chose to preload, so
      # "key absent" there means nothing — read the rows directly, once per
      # post (as prime! would have).
      return post.instance_variable_set(:@mod_whisper_fields, db_fields(post)) if preloaded?(post)

      fields = post.custom_fields
      fields.is_a?(Hash) ? fields : db_fields(post)
    rescue ::HasCustomFields::NotPreloadedError
      db_fields(post)
    end

    def preloaded?(post)
      post.instance_variable_defined?(:@preloaded_custom_fields) &&
        !post.instance_variable_get(:@preloaded_custom_fields).nil?
    end

    def db_fields(post)
      return {} unless post.id
      rows = ::PostCustomField.where(post_id: post.id, name: whisper_fields).pluck(:name, :value)
      rows.each_with_object({}) { |(name, value), h| h[name] = parse_json(value) }
    end
  end
end
