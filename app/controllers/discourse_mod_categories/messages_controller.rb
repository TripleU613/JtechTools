# frozen_string_literal: true

module ::DiscourseModCategories
  # Persistence endpoint for the moderator-set messages. Every action is
  # Guardian-gated so only moderators and admins can write; regular users
  # get a 403.
  class MessagesController < BaseController
    requires_login

    # Whispers and notification auto-mark have their own switches and keep
    # working with the module off; everything else here is the module.
    before_action :ensure_module_enabled,
                  except: %i[
                    update_post_whisper
                    add_whisper_participant
                    mark_topic_notifications_seen
                    mark_review_notifications_seen
                  ]

    TOPIC_FOOTER_FIELD = DiscourseModCategories::TOPIC_FOOTER_FIELD
    TOPIC_REPLY_PROMPT_FIELD = DiscourseModCategories::TOPIC_REPLY_PROMPT_FIELD
    TOPIC_PINNED_POST_FIELD = DiscourseModCategories::TOPIC_PINNED_POST_FIELD
    TOPIC_REQUIRE_REPLY_APPROVAL_FIELD = DiscourseModCategories::TOPIC_REQUIRE_REPLY_APPROVAL_FIELD
    TOPIC_PRIVATE_NOTE_FIELD = DiscourseModCategories::TOPIC_PRIVATE_NOTE_FIELD
    TOPIC_PRIVATE_NOTE_POSITION_FIELD = DiscourseModCategories::TOPIC_PRIVATE_NOTE_POSITION_FIELD
    TOPIC_PRIVATE_NOTE_USER_FIELD = DiscourseModCategories::TOPIC_PRIVATE_NOTE_USER_FIELD
    TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD =
      DiscourseModCategories::TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD
    TOPIC_PRIVATE_NOTE_REPLIES_FIELD = DiscourseModCategories::TOPIC_PRIVATE_NOTE_REPLIES_FIELD
    TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD = DiscourseModCategories::TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD
    USER_NOTES_SEEN_FIELD = DiscourseModCategories::USER_NOTES_SEEN_FIELD
    CATEGORY_NEW_TOPIC_PROMPT_FIELD = DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_FIELD
    TOPIC_REPLY_PROMPT_TL_FIELD = DiscourseModCategories::TOPIC_REPLY_PROMPT_TL_FIELD
    CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD = DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD
    TOPIC_WHISPER_PARTICIPANTS_FIELD = DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD

    def update_topic
      topic = find_topic!

      guardian.ensure_can_manage_mod_messages!

      # Every message flavour is individually feature-gated so an admin can
      # revoke each moderator power from settings, not just the whole module.
      ensure_feature!(:topic_footer_message_enabled) if params.key?(:footer_message)
      if params.key?(:reply_prompt) || params.key?(:reply_prompt_max_tl)
        ensure_feature!(:topic_reply_prompt_enabled)
      end
      ensure_feature!(:mod_pin_post_enabled) if params.key?(:pinned_post_id)
      if params.key?(:require_reply_approval)
        ensure_feature!(:mod_topic_require_reply_approval_enabled)
      end
      if params.key?(:private_note) || params.key?(:private_note_position)
        ensure_feature!(:mod_topic_private_notes_enabled)
        ensure_note_visible!(topic)
      end

      if params.key?(:footer_message)
        topic.custom_fields[TOPIC_FOOTER_FIELD] = params[:footer_message].to_s
      end

      if params.key?(:reply_prompt)
        topic.custom_fields[TOPIC_REPLY_PROMPT_FIELD] = params[:reply_prompt].to_s
      end

      if params.key?(:reply_prompt_max_tl)
        topic.custom_fields[TOPIC_REPLY_PROMPT_TL_FIELD] = normalize_max_tl(
          params[:reply_prompt_max_tl],
        )
      end

      if params.key?(:pinned_post_id)
        raw = params[:pinned_post_id].to_s.strip
        if raw.empty? || raw == "0"
          topic.custom_fields[TOPIC_PINNED_POST_FIELD] = nil
        else
          post = topic.posts.find_by(id: raw.to_i)
          raise Discourse::InvalidParameters.new(:pinned_post_id) unless post
          # A pinned copy is shown to every reader of the topic.
          if DiscourseModCategories::Whisper.whisper?(post)
            raise Discourse::InvalidParameters.new(:pinned_post_id)
          end
          topic.custom_fields[TOPIC_PINNED_POST_FIELD] = post.id
        end
      end

      if params.key?(:require_reply_approval)
        topic.custom_fields[
          TOPIC_REQUIRE_REPLY_APPROVAL_FIELD
        ] = ActiveModel::Type::Boolean.new.cast(params[:require_reply_approval]) || false
      end

      if params.key?(:private_note)
        topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD] = params[:private_note].to_s
        # Record who set the note, and when, so it can be shown like a post.
        topic.custom_fields[TOPIC_PRIVATE_NOTE_USER_FIELD] = current_user.id
        topic.custom_fields[TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD] = Time.zone.now.iso8601
        topic.custom_fields[TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD] = Time.zone.now.iso8601
      end

      if params.key?(:private_note_position)
        position = params[:private_note_position].to_s
        position = "bottom" if %w[top bottom].exclude?(position)
        topic.custom_fields[TOPIC_PRIVATE_NOTE_POSITION_FIELD] = position
      end

      topic.save_custom_fields(true)

      if params.key?(:private_note) && topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD].present? &&
           SiteSetting.mod_notify_staff_on_topic_notes
        notify_staff_of_note(topic)
      end

      render json: {
               footer_message: topic.custom_fields[TOPIC_FOOTER_FIELD].to_s,
               reply_prompt: topic.custom_fields[TOPIC_REPLY_PROMPT_FIELD].to_s,
               reply_prompt_max_tl: topic.custom_fields[TOPIC_REPLY_PROMPT_TL_FIELD],
               pinned_post_id: topic.custom_fields[TOPIC_PINNED_POST_FIELD],
               pinned_post: DiscourseModCategories.serialized_pinned_post(topic, guardian),
               require_reply_approval: !!topic.custom_fields[TOPIC_REQUIRE_REPLY_APPROVAL_FIELD],
               private_note: topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD].to_s,
               private_note_position:
                 topic.custom_fields[TOPIC_PRIVATE_NOTE_POSITION_FIELD].presence || "bottom",
               private_note_author: DiscourseModCategories::NoteThread.author(topic),
             }
    end

    # The per-category new-topic prompt is a moderator message, not a
    # category setting, so it needs the moderator-message right (and a
    # category they can see), not the right to edit the category itself.
    def update_category
      category = Category.find_by(id: params[:category_id])
      raise Discourse::NotFound if category.nil? || !guardian.can_see_category?(category)

      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:precheck_new_topic_enabled)

      if params.key?(:new_topic_prompt)
        category.custom_fields[CATEGORY_NEW_TOPIC_PROMPT_FIELD] = params[:new_topic_prompt].to_s
      end

      if params.key?(:new_topic_prompt_max_tl)
        category.custom_fields[CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD] = normalize_max_tl(
          params[:new_topic_prompt_max_tl],
        )
      end

      category.save_custom_fields(true)

      render json: {
               new_topic_prompt: category.custom_fields[CATEGORY_NEW_TOPIC_PROMPT_FIELD].to_s,
               new_topic_prompt_max_tl: category.custom_fields[CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD],
             }
    end

    # Appends a staff reply to the topic's private moderator note thread.
    def add_note_reply
      topic = find_topic!

      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_topic_private_notes_enabled)
      ensure_note_visible!(topic)

      raw = params[:raw].to_s.strip
      raise Discourse::InvalidParameters.new(:raw) if raw.empty?

      reply = {
        "id" => SecureRandom.hex(8),
        "user_id" => current_user.id,
        "raw" => raw,
        "created_at" => Time.zone.now.iso8601,
      }
      with_note_lock(topic) do
        replies = note_replies(topic)
        replies << reply
        topic.custom_fields[TOPIC_PRIVATE_NOTE_REPLIES_FIELD] = replies
        topic.custom_fields[TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD] = Time.zone.now.iso8601
        topic.save_custom_fields(true)
      end
      notify_staff_of_reply(topic, reply) if SiteSetting.mod_notify_staff_on_topic_notes

      render json: { replies: DiscourseModCategories::NoteThread.replies(topic) }
    end

    # Edits the `raw` body of a single reply in the note thread.
    def update_note_reply
      topic = find_topic!

      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_topic_private_notes_enabled)
      ensure_note_visible!(topic)

      raw = params[:raw].to_s.strip
      raise Discourse::InvalidParameters.new(:raw) if raw.empty?

      reply_id = params[:reply_id].to_s
      with_note_lock(topic) do
        replies = note_replies(topic)
        reply = replies.find { |r| r["id"] == reply_id }
        raise Discourse::InvalidParameters.new(:reply_id) unless reply
        ensure_can_touch_note_entry!(reply["user_id"])

        reply["raw"] = raw
        topic.custom_fields[TOPIC_PRIVATE_NOTE_REPLIES_FIELD] = replies
        topic.custom_fields[TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD] = Time.zone.now.iso8601
        topic.save_custom_fields(true)
      end

      render json: note_thread_json(topic)
    end

    # Removes a single reply from the note thread.
    def delete_note_reply
      topic = find_topic!

      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_topic_private_notes_enabled)
      ensure_note_visible!(topic)

      reply_id = params[:reply_id].to_s
      with_note_lock(topic) do
        replies = note_replies(topic)
        target = replies.find { |r| r["id"] == reply_id }
        raise Discourse::InvalidParameters.new(:reply_id) unless target
        ensure_can_touch_note_entry!(target["user_id"])

        replies.reject! { |r| r["id"] == reply_id }
        topic.custom_fields[TOPIC_PRIVATE_NOTE_REPLIES_FIELD] = replies
        topic.custom_fields[TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD] = Time.zone.now.iso8601
        topic.save_custom_fields(true)
      end

      render json: note_thread_json(topic)
    end

    # Clears the note body, its author/created-at, and its whole reply thread.
    def delete_note
      topic = find_topic!

      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_topic_private_notes_enabled)
      ensure_note_visible!(topic)
      ensure_can_touch_note_entry!(topic.custom_fields[TOPIC_PRIVATE_NOTE_USER_FIELD])

      topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD] = ""
      topic.custom_fields[TOPIC_PRIVATE_NOTE_USER_FIELD] = nil
      topic.custom_fields[TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD] = nil
      topic.custom_fields[TOPIC_PRIVATE_NOTE_REPLIES_FIELD] = []
      topic.custom_fields[TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD] = Time.zone.now.iso8601
      topic.save_custom_fields(true)

      render json: note_thread_json(topic)
    end

    # Toggles or updates a post's whisper state (and audience) after the
    # post already exists. Discourse's PostsController#update path drops
    # whisper params (`add_permitted_post_create_param` is create-only and
    # there's no `serializeOnUpdate` for these fields), so editing a post
    # in the composer and saving doesn't propagate whisper toggles.
    # The frontend calls this endpoint as a follow-up to any staff edit
    # where the whisper state was changed.
    #
    # Staff-only: non-staff users get 403, including the post's own
    # author. A user who didn't have permission to arm a whisper on
    # create shouldn't be able to add or remove one on edit.
    def update_post_whisper
      raise Discourse::NotFound unless SiteSetting.mod_whisper_enabled
      raise Discourse::NotFound unless SiteSetting.mod_whisper_convert_enabled

      post = ::Post.find_by(id: params[:id])
      raise Discourse::NotFound unless post
      raise Discourse::InvalidAccess.new("staff_only") unless current_user.staff?
      raise Discourse::InvalidAccess.new("cannot_edit") unless guardian.can_edit?(post)
      # Hiding or publishing another staff member's post is an admin call.
      if !current_user.admin? && post.user&.staff? && post.user_id != current_user.id
        raise Discourse::InvalidAccess.new("other_staff_post")
      end

      armed = ActiveModel::Type::Boolean.new.cast(params[:mod_whisper])
      was_whisper = DiscourseModCategories::Whisper.whisper?(post)

      # A topic's first post can't be a whisper: title, excerpt and new-topic
      # notifications are public by nature.
      if armed && post.is_first_post?
        raise Discourse::InvalidParameters.new(
                I18n.t("discourse_mod_categories.whisper.first_post_not_allowed"),
              )
      end

      targets_field = DiscourseModCategories::POST_WHISPER_TARGETS_FIELD
      groups_field = DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD
      badges_field = DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD
      admins_only_field = DiscourseModCategories::POST_WHISPER_ADMINS_ONLY_FIELD

      if armed
        cap = DiscourseModCategories::MAX_WHISPER_TARGETS
        user_ids = sanitize_ids(params[:mod_whisper_target_user_ids]).first(cap)
        group_ids = sanitize_ids(params[:mod_whisper_target_group_ids]).first(cap)
        badge_ids = sanitize_ids(params[:mod_whisper_target_badge_ids]).first(cap)
        badge_ids = [] unless SiteSetting.mod_whisper_badge_targeting_enabled

        # Validate IDs against the DB so a typo / stale ID doesn't end up
        # in the custom_fields. on(:post_created) does the same shape.
        user_ids = ::User.where(id: user_ids).pluck(:id) if user_ids.any?
        group_ids = ::Group.where(id: group_ids).pluck(:id) if group_ids.any?
        badge_ids = ::Badge.where(id: badge_ids, enabled: true).pluck(:id) if badge_ids.any?

        post.custom_fields[targets_field] = user_ids
        post.custom_fields[groups_field] = group_ids
        post.custom_fields[badges_field] = badge_ids
        # an admin's whisper is the admins' (moderators only as targets)
        post.custom_fields[admins_only_field] = true if current_user.admin?
        post.save_custom_fields(true)
        if !current_user.admin?
          ::PostCustomField.where(post_id: post.id, name: admins_only_field).destroy_all
        end

        # Explicitly targeted non-staff users may whisper back to staff in
        # this topic. Being a participant grants no visibility at all.
        if post.topic
          DiscourseModCategories::Whisper.merge_participants(
            post.topic,
            ::User.where(id: user_ids).where(admin: false, moderator: false).pluck(:id),
          )
        end
      else
        # Disarming: the `mod_is_whisper` serializer keys off
        # `custom_fields.key?(targets_field)`, so an empty array is NOT
        # enough — the rows have to be physically removed.
        ::PostCustomField.where(
          post_id: post.id,
          name: [targets_field, groups_field, badges_field, admins_only_field],
        ).destroy_all
        post.reload
      end

      # Toggle the search index in lockstep with the whisper state so a
      # search leak doesn't outlive the arm/disarm click. Armed →
      # `post_search_data` row is wiped. Disarmed → the post is re-indexed
      # so it becomes discoverable now that it's public. Listener lives
      # in sub_plugins/mod_categories.rb.
      DiscourseEvent.trigger(:mod_whisper_state_changed, post, armed)

      if armed != was_whisper
        StaffActionLogger.new(current_user).log_custom(
          armed ? "mod_post_made_whisper" : "mod_whisper_made_public",
          post_id: post.id,
          topic_id: post.topic_id,
        )
      end

      render json: serialized_post_whisper_state(post.reload)
    end

    # Records the current staff user as a viewer of the mod-note panel on
    # the given topic. Idempotent — re-viewing updates `viewed_at` on the
    # existing entry rather than appending a duplicate row. The returned
    # `viewers` array drives the "👁 Viewed by N" pill at the bottom of
    # the panel, refreshed inline without a topic reload.
    def record_note_view
      topic = find_topic!

      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_note_view_tracking_enabled)
      ensure_note_visible!(topic)

      # No-op if there's no note to view — keeps stray refresh-on-mount
      # pings from creating viewer rows on topics that never had a note.
      note = topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD].to_s
      raise Discourse::NotFound if note.strip.empty?

      now = Time.zone.now.iso8601
      viewers = nil
      with_note_lock(topic) do
        raw = topic.custom_fields[DiscourseModCategories::TOPIC_NOTE_VIEWERS_FIELD]
        viewers = raw.is_a?(Array) ? raw.deep_dup : []

        existing = viewers.find { |v| v["user_id"].to_i == current_user.id }
        if existing
          existing["viewed_at"] = now
          # Refresh denormalized identity fields in case the user renamed /
          # changed their avatar since their last view.
          existing["username"] = current_user.username
          existing["name"] = current_user.name
          existing["avatar_template"] = current_user.avatar_template
        else
          viewers << {
            "user_id" => current_user.id,
            "username" => current_user.username,
            "name" => current_user.name,
            "avatar_template" => current_user.avatar_template,
            "viewed_at" => now,
          }
        end

        topic.custom_fields[DiscourseModCategories::TOPIC_NOTE_VIEWERS_FIELD] = viewers
        topic.save_custom_fields(true)
      end

      render json: { viewers: DiscourseModCategories::NoteThread.viewers(viewers) }
    end

    # Marks the current user's custom mod-note + whisper notifications for
    # the given topic as read. Called by the frontend whenever the user
    # navigates to a topic page — Discourse's built-in auto-mark-read only
    # covers a hardcoded list of notification types and skips
    # `Notification.types[:custom]`, so plugin notifications about a topic
    # would sit unread in the bell forever even after the user opened the
    # topic. The data-column LIKE filter pins this to our notifications
    # only (mod_note, mod_whisper, and the legacy whisper_notification
    # message key) so unrelated custom notifications another plugin might
    # attach to the same topic are left alone.
    def mark_topic_notifications_seen
      topic = find_topic!

      # Cheap no-op instead of an error when disabled: the frontend pings
      # this on every topic open, and stale clients shouldn't 4xx-spam logs.
      return render json: { marked: 0 } unless SiteSetting.mod_auto_mark_notifications_seen

      marked =
        ::Notification
          .where(
            user_id: current_user.id,
            topic_id: topic.id,
            notification_type: ::Notification.types[:custom],
            read: false,
          )
          .where(
            "data LIKE ? OR data LIKE ? OR data LIKE ?",
            '%"mod_note":true%',
            '%"mod_whisper":true%',
            '%"discourse_mod_categories.whisper.whisper_notification"%',
          )
          .update_all(read: true)

      current_user.publish_notifications_state if marked > 0

      render json: { marked: marked }
    end

    # Marks the current user's mod_note notifications whose `url` points
    # at /review/... as read. Called by the frontend whenever the user
    # navigates to /review or /review/:id — so flag_note / post_rejected
    # / post_approved notifications (which link to /review/:id rather
    # than to a topic page) get marked read on direct navigation, not
    # only via the bell-click or shield-tab-open paths.
    #
    # Scope rules:
    #   - `reviewable_id` param present → mark ONLY notifications whose
    #     data.url is exactly /review/<id> (or starts with /review/<id>/
    #     for sub-paths). Prevents clicking one queued-post notification
    #     from sweeping every other reviewable's notifications read.
    #   - param absent (visiting the /review index) → mark every
    #     /review-anchored mod_note row, matching the original behaviour
    #     since the staff member is viewing all reviewables at once.
    def mark_review_notifications_seen
      guardian.ensure_can_manage_mod_messages!
      return render json: { marked: 0 } unless SiteSetting.mod_auto_mark_notifications_seen

      scope =
        DiscourseModCategories::StaffNotifier.mod_notes_for(current_user.id).where(read: false)

      reviewable_id = params[:reviewable_id].to_s
      if reviewable_id =~ /\A\d+\z/
        scope =
          scope.where(
            "data LIKE ? OR data LIKE ?",
            "%\"url\":\"/review/#{reviewable_id}\"%",
            "%\"url\":\"/review/#{reviewable_id}/%",
          )
      else
        scope = scope.where("data LIKE ?", "%\"url\":\"/review%")
      end

      marked = scope.update_all(read: true)

      current_user.publish_notifications_state if marked > 0

      render json: { marked: marked }
    end

    POST_VIEWERS_CAP = 200

    # Staff-only: who has read a post. Core's post_timings records exactly
    # which posts each logged-in user has had on screen; the closest per-user
    # timestamp core keeps is their last visit to the topic, so that is the
    # "when". Anonymous visitors leave no per-post trace and cannot appear.
    def post_viewers
      raise Discourse::InvalidAccess unless current_user&.staff?
      post = Post.find_by(id: params[:id])
      raise Discourse::NotFound unless post
      guardian.ensure_can_see!(post)

      user_ids =
        PostTiming
          .where(topic_id: post.topic_id, post_number: post.post_number)
          .where("user_id > 0")
          .pluck(:user_id)

      visits =
        TopicUser
          .where(topic_id: post.topic_id, user_id: user_ids)
          .pluck(:user_id, :last_visited_at)
          .to_h

      viewers =
        User
          .where(id: user_ids)
          .sort_by { |user| visits[user.id] || Time.at(0) }
          .reverse
          .first(POST_VIEWERS_CAP)
          .map do |user|
            {
              id: user.id,
              username: user.username,
              name: user.name,
              avatar_template: user.avatar_template,
              last_seen_topic_at: visits[user.id],
            }
          end

      render json: { count: user_ids.length, viewers: viewers }
    end

    # Lists moderator notes for the staff user-menu tab. Returns a UNION:
    # (1) every topic that has a private moderator note set, regardless of
    # whether a Notification fan-out happened — this preserves the
    # original "topics with notes" feed and lets existing system tests
    # that set custom_fields directly still surface; (2) every non-topic
    # event-stream notification (post_deleted / post_approved /
    # post_rejected / user_note / flag_note) the staff user has — these
    # don't have a topic-anchored representation, so they only show via
    # the Notification stream. Newest first within each section, topic
    # section first.
    def notes_feed
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_notes_feed_enabled)

      seen_at = current_user.custom_fields[USER_NOTES_SEEN_FIELD].presence || "1970-01-01T00:00:00Z"

      topic_ids =
        TopicCustomField
          .where(name: TOPIC_PRIVATE_NOTE_FIELD)
          .where.not(value: [nil, ""])
          .order(updated_at: :desc)
          .limit(50)
          .pluck(:topic_id)

      # `Topic.where(id: topic_ids)` doesn't preserve the topic_ids order
      # we just computed (Postgres returns rows in id order, not the order
      # of the IN-list), so index by id and re-iterate in topic_ids order.
      # Critical when several notes share an iso8601 second — the combined
      # recency sort below ties on identical timestamps, and Ruby's stable
      # sort falls back to insertion order; without this, the panel
      # surfaces oldest-first instead of newest-first.
      # Only topics this staff member can read: an admin's note on a private
      # message or an admin-only topic must not surface for moderators.
      topics_by_id =
        Topic
          .includes(:category)
          .where(id: topic_ids)
          .select do |topic|
            guardian.can_see_topic?(topic) &&
              !DiscourseModCategories::NoteThread.hidden_from?(topic, current_user)
          end
          .index_by(&:id)
      # The note fields of all of them in one query, not one per topic.
      Topic.preload_custom_fields(
        topics_by_id.values,
        [
          TOPIC_PRIVATE_NOTE_FIELD,
          TOPIC_PRIVATE_NOTE_REPLIES_FIELD,
          TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD,
        ],
      )
      topic_notes =
        topic_ids
          .map do |id|
            topic = topics_by_id[id]
            next unless topic
            note = topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD].to_s
            next if note.blank?
            replies = topic.custom_fields[TOPIC_PRIVATE_NOTE_REPLIES_FIELD]
            activity_at = topic.custom_fields[TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD].to_s
            {
              kind: "note",
              topic_id: topic.id,
              topic_title: topic.title,
              url: "#{topic.relative_url}/#{topic.highest_post_number}#mod-private-note",
              note: note,
              excerpt: note,
              reply_count: replies.is_a?(Array) ? replies.size : 0,
              activity_at: activity_at,
              created_at: activity_at,
              unread: activity_at > seen_at,
            }
          end
          .compact

      # Non-topic-anchored event notifications: rows whose mod_note_kind
      # is NOT "note" or "reply" (those are already covered by the
      # topic-attached feed above, derived from the topic custom field).
      event_rows =
        DiscourseModCategories::StaffNotifier
          .mod_notes_for(current_user.id)
          .where(
            "data NOT LIKE ? AND data NOT LIKE ?",
            "%\"mod_note_kind\":\"note\"%",
            "%\"mod_note_kind\":\"reply\"%",
          )
          .order(created_at: :desc)
          .limit(50)

      hidden_topic_ids =
        Topic
          .includes(:category)
          .where(id: event_rows.map(&:topic_id).compact.uniq)
          .reject { |topic| guardian.can_see_topic?(topic) }
          .map(&:id)
          .to_set

      events =
        event_rows.filter_map do |n|
          next if n.topic_id && hidden_topic_ids.include?(n.topic_id)
          data =
            begin
              JSON.parse(n.data.to_s)
            rescue StandardError
              {}
            end

          {
            id: n.id,
            kind: data["mod_note_kind"].presence || "note",
            username: data["display_username"],
            topic_id: n.topic_id,
            topic_title: data["topic_title"],
            target_username: data["target_username"],
            excerpt: data["excerpt"].to_s,
            note: data["excerpt"].to_s,
            url: data["url"],
            created_at: n.created_at.iso8601,
            unread: !n.read,
          }
        end

      # Merge both sources into a single recency-sorted list. Rows missing
      # both timestamps fall to the bottom (sort tuple [1, 0]) regardless of
      # how malformed the data is — rescue keeps a corrupt timestamp from
      # 500-ing the feed.
      combined =
        (topic_notes + events).sort_by do |n|
          ts = n[:activity_at].presence || n[:created_at].presence
          begin
            ts.present? ? [0, -Time.zone.parse(ts.to_s).to_i] : [1, 0]
          rescue ArgumentError, TypeError
            [1, 0]
          end
        end

      render json: { notes: combined }
    end

    # Marks the staff user's moderator-note feed as read.
    def notes_feed_seen
      guardian.ensure_can_manage_mod_messages!
      ensure_feature!(:mod_notes_feed_enabled)

      current_user.with_lock do
        current_user.custom_fields[USER_NOTES_SEEN_FIELD] = Time.zone.now.iso8601
        current_user.save_custom_fields(true)
      end

      # Also flip the underlying Notification rows to read. Otherwise the
      # bell counter keeps reflecting the prior mod-note bumps after the
      # shield tab has cleared them — Discourse counts unread Notifications,
      # not our custom seen_at timestamp. The `mod_note` marker in the JSON
      # `data` column distinguishes our notifications from other custom
      # ones so we only touch our own rows.
      marked =
        DiscourseModCategories::StaffNotifier
          .mod_notes_for(current_user.id)
          .where(read: false)
          .update_all(read: true)

      # Push the recalculated bell counts to every open tab so they refresh
      # in lockstep with the shield tab being opened. This also drops the
      # in-dropdown shield-tab pip, which now derives from unread Notification
      # rows (the same source the bell uses), so it stays in lockstep with
      # the bell badge without a dedicated MessageBus channel.
      current_user.publish_notifications_state if marked > 0

      render json: success_json
    end

    # Resolves a badge id to the current set of usernames who hold it.
    # Used by the PM composer "Add badge group" button to splice badge
    # holders into the standard `target_recipients` field — the PM is then
    # sent through the normal PostCreator path with no further plugin code.
    # Self is excluded (no point messaging yourself); the list is deduped.
    #
    # Staff-gated: this enumerates badge holders (usernames in bulk), which
    # is membership data ordinary users have no business harvesting. It was
    # previously open to anyone who could send a PM.
    def badge_members
      ensure_feature!(:mod_pm_badge_group_enabled)
      guardian.ensure_can_manage_mod_messages!
      guardian.ensure_can_send_private_messages!
      badge = Badge.find_by(id: params[:badge_id])
      raise Discourse::NotFound unless badge

      usernames =
        User
          .joins(:user_badges)
          .where(user_badges: { badge_id: badge.id })
          .where(active: true)
          .where.not(id: current_user.id)
          .distinct
          .pluck(:username)

      render json: { usernames: usernames, badge: { id: badge.id, name: badge.display_name } }
    end

    # Adds users to ONE whisper's audience (its explicit target users). They
    # see that whisper — and, because staff replies carry the audience
    # forward, the conversation that follows it — but never other whispers
    # in the topic: a whisper is visible to exactly who its banner names.
    def add_whisper_participant
      raise Discourse::NotFound unless SiteSetting.mod_whisper_enabled
      raise Discourse::NotFound unless SiteSetting.mod_whisper_add_participant_enabled

      topic = find_topic!

      # Whisper-scoped guard, not ensure_can_manage_mod_messages! — that
      # Guardian rides on mod_categories_enabled, and whispers are
      # deliberately independent of the module master.
      raise Discourse::InvalidAccess unless current_user&.staff?

      post = topic.posts.find_by(id: params[:post_id])
      # not a whisper they can't see (an admin's, for a moderator)
      post = nil if post && !DiscourseModCategories::Whisper.visible_to?(post, current_user)
      unless post && DiscourseModCategories::Whisper.whisper?(post)
        raise Discourse::InvalidParameters.new(
                I18n.t("discourse_mod_categories.whisper.add_participant_needs_whisper"),
              )
      end

      user =
        if params[:user_id].present?
          User.find_by(id: params[:user_id])
        elsif params[:username].present?
          User.find_by_username(params[:username])
        end
      raise Discourse::InvalidParameters.new(:username) unless user

      targets_field = DiscourseModCategories::POST_WHISPER_TARGETS_FIELD
      existing = DiscourseModCategories::Whisper.normalize_ids(post.custom_fields[targets_field])
      added = existing.exclude?(user.id)

      if added
        post.custom_fields[targets_field] = existing + [user.id]
        post.save_custom_fields(true)
        DiscourseModCategories::Whisper.merge_participants(topic, [user.id]) unless user.staff?
        notify_whisper_participant(topic, post, user)
        post.publish_change_to_clients!(:revised)
      end

      render json: {
               participant_ids:
                 DiscourseModCategories::Whisper.normalize_ids(
                   topic.custom_fields[TOPIC_WHISPER_PARTICIPANTS_FIELD],
                 ),
               **serialized_post_whisper_state(post.reload),
             }
    end

    private

    # Every topic endpoint works only on topics the caller can see: a
    # moderator must not set a footer, reply approval, note or checklist on
    # (or read the note of) a private message or restricted topic they can't
    # read.
    # The note thread and its viewer list are JSON in topic custom fields;
    # a read-modify-write without a lock would let two staff saving at once
    # drop one of the changes.
    def with_note_lock(topic)
      DistributedMutex.synchronize("mod_topic_note_#{topic.id}") do
        topic.reload
        yield
      end
    end

    # 404s when a per-feature toggle is off — same shape the whisper
    # endpoints already use for their master switch.
    # Note-thread entries are editable/deletable by their author and by
    # admins; other moderators only when the site explicitly opts in via
    # mod_moderators_can_edit_others_notes (default off — previously any
    # moderator could silently rewrite a colleague's note).
    # An admin's note thread doesn't exist for a moderator: not to read, reply
    # to, edit, delete or write over
    def ensure_note_visible!(topic)
      if DiscourseModCategories::NoteThread.hidden_from?(topic, current_user)
        raise Discourse::NotFound
      end
    end

    def ensure_can_touch_note_entry!(author_id)
      return if current_user.admin?
      return if author_id.to_i == current_user.id
      return if SiteSetting.mod_moderators_can_edit_others_notes
      raise Discourse::InvalidAccess.new("not_note_author")
    end

    # Notifies a newly added user that they were added to a whisper,
    # mirroring the whisper `post_created` notification pattern.
    def notify_whisper_participant(topic, post, user)
      return unless SiteSetting.mod_notify_whisper_targets
      return if user.id == current_user.id

      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: user.id,
        topic_id: topic.id,
        post_number: post.post_number,
        data: {
          topic_title: topic.title,
          display_username: current_user.username,
          mod_whisper: true,
          original_post_id: post.id,
          message: "discourse_mod_categories.whisper.whisper_notification",
        }.to_json,
      )
    end

    # Clamps a submitted trust-level cap to 0-4. 4 (the default) means the
    # prompt is shown to everyone; 0-3 limits it to that trust level and
    # below.
    def normalize_max_tl(value)
      [[value.to_i, 0].max, 4].min
    end

    # Sends a real Discourse notification (bell + live pop-up) to every
    # other staff member when a moderator note or reply is added.
    #
    # The notification carries `high_priority: true` so it sorts and badges
    # like a flag/review notification, and a `mod_note` marker in `data` so
    # the frontend notification-type renderer can render it with the shield
    # icon, accurate text, and a link straight to the moderator note. The
    # note lives on the topic, so the link resolves to the topic at its
    # highest post number with a `#mod-private-note` anchor so the browser
    # (and the component's own scroll-into-view) lands on the note section
    # instead of the topic's first post when the topic is short.
    #
    # The live pop-up alert is published on the same `/notification-alert/`
    # MessageBus channel core uses for flags/replies. Creating a
    # `Notification` row alone only fills the bell list — it never pops up.
    def notify_staff_of_note(topic)
      notify_staff_of_thread(
        topic,
        kind: "note",
        text: topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD].to_s,
        url: "#{topic.relative_url}/#{topic.highest_post_number}#mod-private-note",
      )
    end

    # Sends a notification for a single reply in the moderator-note thread.
    # Each reply gets its own bell row and live pop-up — carrying the reply
    # author, the reply excerpt, and a URL anchored at the specific reply —
    # so multiple replies in the same topic stack as distinct entries instead
    # of looking like duplicate "note added" rows.
    def notify_staff_of_reply(topic, reply)
      reply_id = reply["id"].to_s
      notify_staff_of_thread(
        topic,
        kind: "reply",
        text: reply["raw"].to_s,
        url:
          "#{topic.relative_url}/#{topic.highest_post_number}#mod-private-note-reply-#{reply_id}",
        extra: {
          reply_id: reply_id,
        },
      )
    end

    # A bell row and a live pop-up for each staff member who may see the
    # topic. A note and a reply differ only in their kind, text and link,
    # the reply's id, and the words ("added a note" / "replied to").
    def notify_staff_of_thread(topic, kind:, text:, url:, extra: {})
      key = kind == "reply" ? "note_reply_notification" : "note_notification"
      excerpt = text.truncate(300)

      DiscourseModCategories::StaffNotifier
        .staff_recipients(
          except: current_user,
          topic: topic,
          admins_only: DiscourseModCategories::NoteThread.admins_only?(topic),
        )
        .each do |staff_user|
          data = {
            topic_title: topic.title,
            display_username: current_user.username,
            # Stable marker the frontend renderer keys off to recognize THIS
            # custom notification as a moderator note.
            mod_note: true,
            mod_note_kind: kind,
            **extra,
            excerpt: excerpt,
            url: url,
            message: "discourse_mod_categories.#{key}",
            title: "discourse_mod_categories.#{key}_title",
          }

          Notification.create!(
            notification_type: Notification.types[:custom],
            user_id: staff_user.id,
            topic_id: topic.id,
            post_number: topic.highest_post_number,
            high_priority: true,
            data: data.to_json,
          )

          publish_note_alert(
            staff_user,
            topic,
            excerpt,
            url,
            "discourse_mod_categories.#{key}_alert",
          )
          # Core publishes the new unread count once the row commits, which
          # refreshes the bell dot and the shield-tab pip together.
        end
    end

    # Fires the small live notification pop-up for one staff member. The
    # payload mirrors `PostAlerter.create_notification_alert`, but carries an
    # explicit `translated_title` so the pop-up text clearly names a
    # moderator note (or a reply to one), and a `post_url` pointing straight
    # at it.
    def publish_note_alert(staff_user, topic, excerpt, url, title_key)
      return if staff_user.suspended?
      return unless staff_user.allow_live_notifications?

      payload = {
        notification_type: Notification.types[:custom],
        topic_title: topic.title,
        topic_id: topic.id,
        post_number: topic.highest_post_number,
        excerpt: excerpt,
        username: current_user.username,
        post_url: url,
        translated_title: I18n.t(title_key, username: current_user.username, topic: topic.title),
      }

      MessageBus.publish("/notification-alert/#{staff_user.id}", payload, user_ids: [staff_user.id])
    end

    # Reads the topic's reply thread, backfilling a stable `id` onto any
    # legacy reply that predates ids so edit/delete can target it.
    def note_replies(topic)
      replies = topic.custom_fields[TOPIC_PRIVATE_NOTE_REPLIES_FIELD]
      replies = [] unless replies.is_a?(Array)
      replies.each { |entry| entry["id"] = DiscourseModCategories.note_reply_id(entry) }
      replies
    end

    # The updated note + replies JSON returned by every note-thread action so
    # the frontend can refresh without an extra request.
    def note_thread_json(topic)
      {
        private_note: topic.custom_fields[TOPIC_PRIVATE_NOTE_FIELD].to_s,
        private_note_author: DiscourseModCategories::NoteThread.author(topic),
        private_note_created_at: topic.custom_fields[TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD],
        replies: DiscourseModCategories::NoteThread.replies(topic),
      }
    end

    # Strips/dedupes ID arrays sent by the composer for whisper target
    # update. Casts to ints, drops zero/nil, dedupes. Both endpoints
    # (update_post_whisper) and the on(:post_created) hook share this
    # shape so they normalize identically.
    def sanitize_ids(raw)
      Array(raw).map(&:to_i).reject(&:zero?).uniq
    end

    # Mirrors the post serializer's whisper fields so the frontend can
    # swap the response in for the post's local state without a topic
    # reload. The four ids* fields match the existing :post serializer
    # overrides in sub_plugins/mod_categories.rb.
    def serialized_post_whisper_state(post)
      targets_field = DiscourseModCategories::POST_WHISPER_TARGETS_FIELD
      {
        mod_is_whisper: post.custom_fields.key?(targets_field),
        mod_whisper_target_user_ids: Array(post.custom_fields[targets_field]).map(&:to_i),
        mod_whisper_target_group_ids:
          Array(post.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD]).map(
            &:to_i
          ),
        mod_whisper_target_badge_ids:
          Array(post.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD]).map(
            &:to_i
          ),
      }
    end
  end
end
