# frozen_string_literal: true
# Jtech sub-plugin body, lifted from `discourse-mod/plugin.rb` of the original plugin.
# This file is instance_eval'd by Jtech/plugin.rb in the Plugin::Instance context,
# so DSL methods (after_initialize, register_asset, on, …) work unchanged.

require_relative "../lib/discourse_mod_categories/guardian_extensions"
require_relative "../lib/discourse_mod_categories/whisper"
require_relative "../lib/discourse_mod_categories/core_whisper_patches"
require_relative "../lib/discourse_mod_categories/whisper_query_filter"
require_relative "../lib/discourse_mod_categories/whisper_unread"
require_relative "../lib/discourse_mod_categories/staff_notifier"
require_relative "../lib/discourse_mod_categories/note_thread"
require_relative "../lib/discourse_mod_categories/user_action_whisper_filter"
require_relative "../lib/discourse_mod_categories/search_indexer_extension"
require_relative "../lib/discourse_mod_categories/search_extension"

register_asset "stylesheets/topic-footer-message.scss"
register_asset "stylesheets/whisper.scss"
register_asset "stylesheets/notifications-type-filter.scss"
register_asset "stylesheets/mod-notes-panel.scss"
register_svg_icon "align-left"
register_svg_icon "clock-rotate-left"
register_svg_icon "up-right-from-square"
register_svg_icon "list-check"
register_svg_icon "shield-halved"
register_svg_icon "user-plus"
register_svg_icon "pencil"
register_svg_icon "trash-can"
register_svg_icon "certificate"
register_svg_icon "eye"

module ::DiscourseModCategories
  # Module switch AND the bundle master (jtech_enabled). Discourse's own
  # plugin gate stops event hooks, serializers and assets when the master is
  # off, but not the core-class patches or scheduled jobs, so every read of
  # this module's switch goes through here.
  def self.enabled?
    SiteSetting.jtech_enabled && SiteSetting.mod_categories_enabled
  end

  # Custom-field keys for the moderator-set messages.
  TOPIC_FOOTER_FIELD = "mod_topic_footer_message"
  TOPIC_REPLY_PROMPT_FIELD = "mod_topic_reply_prompt"
  TOPIC_PINNED_POST_FIELD = "mod_topic_pinned_post_id"
  TOPIC_REQUIRE_REPLY_APPROVAL_FIELD = "mod_topic_require_reply_approval"
  TOPIC_PRIVATE_NOTE_FIELD = "mod_topic_private_note"
  TOPIC_PRIVATE_NOTE_POSITION_FIELD = "mod_topic_private_note_position"
  TOPIC_PRIVATE_NOTE_USER_FIELD = "mod_topic_private_note_user_id"
  TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD = "mod_topic_private_note_created_at"
  TOPIC_PRIVATE_NOTE_REPLIES_FIELD = "mod_topic_private_note_replies"
  TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD = "mod_topic_private_note_activity_at"
  USER_NOTES_SEEN_FIELD = "mod_notes_seen_at"
  CATEGORY_NEW_TOPIC_PROMPT_FIELD = "mod_category_new_topic_prompt"
  # Highest trust level still shown a prompt (0-3); 4/blank means everyone.
  TOPIC_REPLY_PROMPT_TL_FIELD = "mod_topic_reply_prompt_max_tl"
  CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD = "mod_category_new_topic_prompt_max_tl"
  # Forum-wide first-post checklist: the config lives in the plugin store,
  # and each user records the highest checklist version they have accepted.
  USER_CHECKLIST_VERSION_FIELD = "mod_checklist_accepted_version"
  CHECKLIST_STORE_NAMESPACE = "discourse_mod_categories"
  CHECKLIST_STORE_KEY = "first_post_checklist"
  # Append-only audit log of checklist acceptances.
  CHECKLIST_LOG_KEY = "first_post_checklist_log"
  # Targeted checklists: separate checklists aimed at specific users,
  # stored as a JSON array under this key. A per-user json map records the
  # version each targeted checklist was last accepted at.
  TARGETED_CHECKLISTS_KEY = "targeted_checklists"
  USER_TARGETED_CHECKLIST_FIELD = "mod_checklist_targeted_accepted"
  # Per-topic prompt checklist: an opt-in checklist attached to a single
  # topic. The checklist itself lives on the topic custom field; each user
  # records which version (per topic id) they have accepted in their own
  # json map custom field.
  TOPIC_PROMPT_CHECKLIST_FIELD = "mod_topic_prompt_checklist"
  USER_TOPIC_CHECKLIST_FIELD = "mod_topic_checklist_accepted"

  # Render data for the topic's pinned-to-bottom post, or nil when the topic
  # has no pinned post (or the pinned post has been deleted out from under
  # the custom field). Shared by the `:mod_topic_pinned_post` serializer and
  # the `update_topic` controller response so a freshly-pinned post renders
  # the bottom copy live, without a page reload, even when the post isn't in
  # the currently-loaded post-stream window.
  def self.serialized_pinned_post(topic, guardian)
    return nil unless topic
    id = topic.custom_fields[TOPIC_PINNED_POST_FIELD]
    return nil if id.blank?
    post = topic.posts.find_by(id: id.to_i)
    return nil unless post
    # Never render a copy of a post the viewer can't see (a whisper, a
    # hidden or deleted post).
    return nil unless guardian&.can_see_post?(post)
    user = post.user
    {
      id: post.id,
      post_number: post.post_number,
      cooked: post.cooked,
      username: user&.username,
      name: user&.name,
      avatar_template: user&.avatar_template,
    }
  end

  # A note reply's id. Replies saved before replies had ids get one derived
  # from their content, so it is the same on every render and edit/delete
  # can find them.
  def self.note_reply_id(entry)
    entry["id"].presence ||
      Digest::SHA1.hexdigest([entry["user_id"], entry["created_at"], entry["raw"]].join("\0"))[
        0,
        16
      ]
  end

  # The current checklist config, or nil when none is set. Shape:
  #   { "version" => Integer, "items" => [{ "label" =>, "url" => }],
  #     "updated_at" => ISO8601 String }
  def self.checklist_config
    PluginStore.get(CHECKLIST_STORE_NAMESPACE, CHECKLIST_STORE_KEY)
  end

  # The single checklist the given user most needs to accept before they
  # can post, or nil so the caller can skip the modal. This is the SINGLE
  # source of truth shared by the `mod_first_post_checklist` serializer and
  # the `/checklist/owed` endpoint, so the two can never diverge.
  #
  # Priority: targeted > per-topic > global. A targeted checklist applies
  # regardless of trust level or staff status. A per-topic checklist, when
  # `topic_id` is supplied, applies to every user (including staff) who
  # has not yet accepted the current version for that topic. Failing both,
  # the forum-wide checklist applies under the usual rules (non-staff,
  # trust-level cap). A user owing several is shown the highest-priority one.
  def self.owed_checklist_for(user, topic_id: nil)
    return nil unless user
    return nil unless DiscourseModCategories.enabled?

    # --- Targeted checklists (override trust level and moderator status) ---
    # Admins are exempt: a moderator-authored targeted checklist must never
    # be able to gate an admin's posting.
    targeted_accepted = user.custom_fields[USER_TARGETED_CHECKLIST_FIELD]
    targeted_accepted = {} unless targeted_accepted.is_a?(Hash)

    owed_targeted =
      if SiteSetting.mod_targeted_checklists_enabled && !user.admin?
        targeted_checklists.find do |checklist|
          items = checklist["items"]
          next false unless items.is_a?(Array) && items.any?
          next false if Array(checklist["user_ids"]).map(&:to_i).exclude?(user.id)
          checklist["version"].to_i > targeted_accepted[checklist["id"]].to_i
        end
      end

    if owed_targeted
      return(
        {
          kind: "targeted",
          id: owed_targeted["id"],
          version: owed_targeted["version"].to_i,
          items: owed_targeted["items"],
          button_label: owed_targeted["button_label"].to_s,
          updated_at: owed_targeted["updated_at"],
        }
      )
    end

    # --- Per-topic checklist (applies to everyone, including staff) ---
    # Mode is "checklist" (the default historical shape) or "statement"
    # (a single message + accept button). Frequency is "once" (default,
    # per-user-version-tracked) or "every_reply" (always prompt). A
    # max_tl cap filters higher-trust non-staff users out. Targeted
    # checklists already short-circuited above so they always show.
    if topic_id.present? && SiteSetting.mod_topic_prompt_checklist_enabled
      topic_checklist = topic_prompt_checklist(topic_id)
      if topic_checklist
        mode = topic_checklist["mode"].to_s
        mode = "checklist" if %w[statement checklist].exclude?(mode)
        frequency = topic_checklist["frequency"].to_s
        frequency = "once" if %w[once every_reply].exclude?(frequency)

        max_tl =
          if topic_checklist.key?("max_tl")
            topic_checklist["max_tl"].to_i
          else
            4
          end

        # Trust-level cap (non-staff only); 4 = everyone.
        below_cap = !user.staff? && user.trust_level > max_tl

        unless below_cap
          version = topic_checklist["version"].to_i
          accepted_version = 0
          if frequency == "once"
            accepted_map = user.custom_fields[USER_TOPIC_CHECKLIST_FIELD]
            accepted_map =
              begin
                JSON.parse(accepted_map)
              rescue StandardError
                {}
              end if accepted_map.is_a?(String)
            accepted_map = {} unless accepted_map.is_a?(Hash)
            accepted_version = accepted_map[topic_id.to_s].to_i
          end

          if frequency == "every_reply" || version > accepted_version
            return(
              {
                kind: "topic",
                id: topic_id.to_i,
                version: version,
                mode: mode,
                statement: topic_checklist["statement"].to_s,
                items: topic_checklist["items"],
                frequency: frequency,
                max_tl: max_tl,
                button_label: topic_checklist["button_label"].to_s,
                updated_at: topic_checklist["updated_at"],
              }
            )
          end
        end
      end
    end

    # --- Forum-wide checklist (staff excluded, trust-level cap) ---
    return nil if user.staff?
    return nil unless SiteSetting.mod_first_post_checklist_enabled

    config = checklist_config
    return nil unless config

    items = config["items"]
    return nil unless items.is_a?(Array) && items.any?

    # Highest trust level still required to accept (default TL2).
    max_tl = config.key?("max_tl") ? config["max_tl"].to_i : 2
    return nil if user.trust_level > max_tl

    version = config["version"].to_i
    accepted = user.custom_fields[USER_CHECKLIST_VERSION_FIELD].to_i
    return nil if accepted >= version

    {
      kind: "global",
      version: version,
      items: items,
      button_label: config["button_label"].to_s,
      updated_at: config["updated_at"],
    }
  end

  # The per-topic prompt checklist hash for a given topic, or nil. Returns
  # the parsed json structure when the config is active (checklist mode
  # with at least one item, or statement mode with a non-blank statement),
  # else nil to mean "inactive". The custom field stores json, so the
  # value may already be a hash; older saves may have stored a string, so
  # coerce that case too.
  def self.topic_prompt_checklist(topic_id)
    return nil if topic_id.blank?
    topic = Topic.find_by(id: topic_id)
    return nil unless topic

    raw = topic.custom_fields[TOPIC_PROMPT_CHECKLIST_FIELD]
    raw =
      begin
        JSON.parse(raw)
      rescue StandardError
        nil
      end if raw.is_a?(String)
    return nil unless raw.is_a?(Hash)

    mode = raw["mode"].to_s
    mode = "checklist" if %w[statement checklist].exclude?(mode)

    if mode == "statement"
      return nil if raw["statement"].to_s.strip.empty?
    else
      items = raw["items"]
      return nil unless items.is_a?(Array) && items.any?
    end

    raw
  end

  # The list of targeted checklists, an array of
  #   { "id", "name", "user_ids" => [Integer], "items" => [{ "label", "url" }],
  #     "version" => Integer, "button_label" }
  def self.targeted_checklists
    raw = PluginStore.get(CHECKLIST_STORE_NAMESPACE, TARGETED_CHECKLISTS_KEY)
    raw.is_a?(Array) ? raw : []
  end

  # Moderator whisper: a per-post custom field holding the chosen target user
  # ids (json int array). KEY PRESENCE marks the post as a whisper — even an
  # empty `[]` array (a staff-only whisper-back). The per-topic field holds
  # the cumulative set of non-staff users ever whispered to in the topic.
  POST_WHISPER_TARGETS_FIELD = "mod_whisper_target_user_ids"
  # A whisper may also target whole groups; this per-post field holds the
  # chosen group ids (json int array). A member of ANY target group can see
  # the whisper. User targets and group targets are independent — a whisper
  # may carry either, both, or neither (an all-empty staff whisper).
  POST_WHISPER_TARGET_GROUPS_FIELD = "mod_whisper_target_group_ids"
  # A whisper may target the holders of one or more badges; this per-post
  # field holds the chosen badge ids (json int array). Membership is
  # evaluated lazily at query time, so a user who later earns the badge
  # gains visibility and a user who loses it loses visibility — same shape
  # as group targets.
  POST_WHISPER_TARGET_BADGES_FIELD = "mod_whisper_target_badge_ids"
  # Marks a whisper an admin wrote (and anything answering one): moderators
  # see it only when its targets include them, like anybody else. Presence
  # is the mark.
  POST_WHISPER_ADMINS_ONLY_FIELD = "mod_whisper_admins_only"
  TOPIC_WHISPER_PARTICIPANTS_FIELD = "mod_whisper_participant_ids"
  # JSON array of `{user_id, username, name, avatar_template, viewed_at}`
  # entries — staff who have rendered the mod-note panel on the topic.
  # Used by the "👁 Viewed by N" pill at the bottom of the panel. Re-view
  # updates the entry's `viewed_at` in place (one row per user).
  TOPIC_NOTE_VIEWERS_FIELD = "mod_topic_note_viewers"
  MAX_WHISPER_TARGETS = 10
  # Explicit boolean armed flag sent by the composer. A boolean survives
  # form-encoding even when the target id array is empty, so it — not the
  # target count — is the single source of truth for "this post is a whisper".
  POST_WHISPER_ARMED_PARAM = "mod_whisper"

  # Highest post_number in the topic that the given user can actually see —
  # i.e. excluding whispers whose audience does not include them. Used as the
  # per-user serialized `highest_post_number` so the topic-list unread badge
  # is audience-aware: non-audience viewers see no badge bump from whispers,
  # while audience members (staff, explicit user/group targets, topic whisper
  # participants) see the whisper post count toward unread.
  def self.whisper_audience_max_post_number(topic, user)
    return nil unless topic
    scope =
      ::Post.where(topic_id: topic.id, deleted_at: nil, post_type: ::Topic.visible_post_types(user))
    scope = WhisperQueryFilter.apply(scope, user)
    scope.maximum(:post_number)
  end

  class Engine < ::Rails::Engine
    engine_name "discourse_mod_categories"
    isolate_namespace DiscourseModCategories
  end
end

after_initialize do
  reloadable_patch { ::Guardian.prepend(DiscourseModCategories::GuardianExtensions) }

  # Keep the shield-tab pip in sync when a mod-note notification is marked
  # read from the standard bell dropdown. The reverse direction (opening the
  # shield tab → marking the bell rows read) is already wired in
  # MessagesController#notes_feed_seen via publish_notifications_state. This
  # hook gives a single-row bell mark-read the same effect: republishing the
  # bell count tells the user-state poll that the unread total dropped, and
  # the next /session/current.json (or current-user serializer refresh) picks
  # up the recomputed mod_note_unread_count.
  reloadable_patch do
    ::Notification.after_update_commit do
      next unless saved_change_to_read?
      next unless read
      next unless notification_type == ::Notification.types[:custom]
      next if data.to_s.exclude?('"mod_note":true')
      next unless DiscourseModCategories.enabled? && SiteSetting.mod_notes_feed_enabled
      user = ::User.find_by(id: user_id)
      user&.publish_notifications_state
    end
  end

  # Per-topic and per-category storage for the moderator-set messages.
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_FOOTER_FIELD, :string)
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_REPLY_PROMPT_FIELD, :string)
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_PINNED_POST_FIELD, :integer)
  register_topic_custom_field_type(
    DiscourseModCategories::TOPIC_REQUIRE_REPLY_APPROVAL_FIELD,
    :boolean,
  )
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_PRIVATE_NOTE_FIELD, :string)
  register_topic_custom_field_type(
    DiscourseModCategories::TOPIC_PRIVATE_NOTE_POSITION_FIELD,
    :string,
  )
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_PRIVATE_NOTE_USER_FIELD, :integer)
  register_topic_custom_field_type(
    DiscourseModCategories::TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD,
    :string,
  )
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_PRIVATE_NOTE_REPLIES_FIELD, :json)
  register_topic_custom_field_type(
    DiscourseModCategories::TOPIC_PRIVATE_NOTE_ACTIVITY_FIELD,
    :string,
  )
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_NOTE_VIEWERS_FIELD, :json)

  # Preloaded on topic lists so reading it from a list row can't raise
  # HasCustomFields::NotPreloadedError (or cost a query per row).
  add_preloaded_topic_list_custom_field(DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD)
  register_user_custom_field_type(DiscourseModCategories::USER_NOTES_SEEN_FIELD, :string)
  register_user_custom_field_type(DiscourseModCategories::USER_CHECKLIST_VERSION_FIELD, :integer)
  register_user_custom_field_type(DiscourseModCategories::USER_TARGETED_CHECKLIST_FIELD, :json)
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_PROMPT_CHECKLIST_FIELD, :json)
  register_user_custom_field_type(DiscourseModCategories::USER_TOPIC_CHECKLIST_FIELD, :json)
  register_category_custom_field_type(
    DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_FIELD,
    :string,
  )
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_REPLY_PROMPT_TL_FIELD, :integer)
  register_category_custom_field_type(
    DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD,
    :integer,
  )

  # Expose the per-topic messages to the topic view so the frontend can
  # read them without an extra request.
  add_to_serializer(
    :topic_view,
    :mod_topic_footer_message,
    include_condition: -> do
      DiscourseModCategories.enabled? && SiteSetting.topic_footer_message_enabled
    end,
  ) { object.topic.custom_fields[DiscourseModCategories::TOPIC_FOOTER_FIELD] }
  add_to_serializer(
    :topic_view,
    :mod_topic_reply_prompt,
    include_condition: -> do
      DiscourseModCategories.enabled? && SiteSetting.topic_reply_prompt_enabled
    end,
  ) { object.topic.custom_fields[DiscourseModCategories::TOPIC_REPLY_PROMPT_FIELD] }
  add_to_serializer(
    :topic_view,
    :mod_topic_reply_prompt_max_tl,
    include_condition: -> do
      DiscourseModCategories.enabled? && SiteSetting.topic_reply_prompt_enabled
    end,
  ) { object.topic.custom_fields[DiscourseModCategories::TOPIC_REPLY_PROMPT_TL_FIELD] }
  add_to_serializer(
    :topic_view,
    :mod_topic_pinned_post_id,
    include_condition: -> { DiscourseModCategories.enabled? && SiteSetting.mod_pin_post_enabled },
  ) { object.topic.custom_fields[DiscourseModCategories::TOPIC_PINNED_POST_FIELD] }
  # The pinned post's render data, attached to the topic so the bottom-copy
  # connector renders without needing the post to be in the currently-loaded
  # `postStream.posts` window — pinning a post far above the current scroll
  # position would otherwise leave the footer blank until reload.
  add_to_serializer(
    :topic_view,
    :mod_topic_pinned_post,
    include_condition: -> { DiscourseModCategories.enabled? && SiteSetting.mod_pin_post_enabled },
  ) { DiscourseModCategories.serialized_pinned_post(object.topic, scope) }
  add_to_serializer(
    :topic_view,
    :mod_topic_require_reply_approval,
    include_condition: -> do
      DiscourseModCategories.enabled? && SiteSetting.mod_topic_require_reply_approval_enabled
    end,
  ) { !!object.topic.custom_fields[DiscourseModCategories::TOPIC_REQUIRE_REPLY_APPROVAL_FIELD] }

  # The per-topic prompt checklist — surfaced on the topic so the
  # frontend editor modal can read its current state, and the gate can
  # detect an active checklist without an extra round trip.
  add_to_serializer(
    :topic_view,
    :mod_topic_prompt_checklist,
    include_condition: -> do
      DiscourseModCategories.enabled? && SiteSetting.mod_topic_prompt_checklist_enabled
    end,
  ) do
    raw = object.topic.custom_fields[DiscourseModCategories::TOPIC_PROMPT_CHECKLIST_FIELD]
    raw =
      begin
        JSON.parse(raw)
      rescue StandardError
        nil
      end if raw.is_a?(String)
    next nil unless raw.is_a?(Hash)
    items = raw["items"].is_a?(Array) ? raw["items"] : []
    mode = raw["mode"].to_s
    mode = "checklist" if %w[statement checklist].exclude?(mode)
    frequency = raw["frequency"].to_s
    frequency = "once" if %w[once every_reply].exclude?(frequency)
    max_tl = raw.key?("max_tl") ? raw["max_tl"].to_i : 4
    # An inactive (mode=statement with blank statement, or mode=checklist
    # with no items) config serializes to null — the gate skips it anyway.
    if mode == "statement"
      next nil if raw["statement"].to_s.strip.empty?
    else
      next nil if items.empty?
    end
    {
      version: raw["version"].to_i,
      mode: mode,
      statement: raw["statement"].to_s,
      items: items,
      frequency: frequency,
      max_tl: max_tl,
      button_label: raw["button_label"].to_s,
      updated_at: raw["updated_at"],
    }
  end

  # The private moderator note is only ever serialized to staff, so a
  # regular user's topic JSON never contains it; an admin's, to admins.
  add_to_serializer(
    :topic_view,
    :mod_topic_private_note,
    include_condition: -> do
      scope.is_staff? && DiscourseModCategories.enabled? &&
        SiteSetting.mod_topic_private_notes_enabled &&
        !DiscourseModCategories::NoteThread.hidden_from?(object.topic, scope.user)
    end,
  ) { object.topic.custom_fields[DiscourseModCategories::TOPIC_PRIVATE_NOTE_FIELD] }
  add_to_serializer(
    :topic_view,
    :mod_topic_private_note_position,
    include_condition: -> do
      scope.is_staff? && DiscourseModCategories.enabled? &&
        SiteSetting.mod_topic_private_notes_enabled &&
        !DiscourseModCategories::NoteThread.hidden_from?(object.topic, scope.user)
    end,
  ) { object.topic.custom_fields[DiscourseModCategories::TOPIC_PRIVATE_NOTE_POSITION_FIELD] }
  # Who set the note — staff only, so the note can be shown like a post.
  add_to_serializer(
    :topic_view,
    :mod_topic_private_note_author,
    include_condition: -> do
      scope.is_staff? && DiscourseModCategories.enabled? &&
        SiteSetting.mod_topic_private_notes_enabled &&
        !DiscourseModCategories::NoteThread.hidden_from?(object.topic, scope.user)
    end,
  ) { DiscourseModCategories::NoteThread.author(object.topic) }
  add_to_serializer(
    :topic_view,
    :mod_topic_private_note_created_at,
    include_condition: -> do
      scope.is_staff? && DiscourseModCategories.enabled? &&
        SiteSetting.mod_topic_private_notes_enabled &&
        !DiscourseModCategories::NoteThread.hidden_from?(object.topic, scope.user)
    end,
  ) { object.topic.custom_fields[DiscourseModCategories::TOPIC_PRIVATE_NOTE_CREATED_AT_FIELD] }
  # The thread of staff replies to the note.
  add_to_serializer(
    :topic_view,
    :mod_topic_private_note_replies,
    include_condition: -> do
      scope.is_staff? && DiscourseModCategories.enabled? &&
        SiteSetting.mod_topic_private_notes_enabled &&
        !DiscourseModCategories::NoteThread.hidden_from?(object.topic, scope.user)
    end,
  ) { DiscourseModCategories::NoteThread.replies(object.topic) }

  # Staff who have rendered the mod-note panel on this topic — used by the
  # "👁 Viewed by N" pill at the bottom of the panel. Newest viewer last,
  # so the UI can show the most recent at the top when reversed.
  add_to_serializer(
    :topic_view,
    :mod_topic_note_viewers,
    include_condition: -> do
      scope.is_staff? && DiscourseModCategories.enabled? &&
        SiteSetting.mod_note_view_tracking_enabled &&
        !DiscourseModCategories::NoteThread.hidden_from?(object.topic, scope.user)
    end,
  ) do
    DiscourseModCategories::NoteThread.viewers(
      object.topic.custom_fields[DiscourseModCategories::TOPIC_NOTE_VIEWERS_FIELD],
    )
  end

  # Unread moderator-note count, for the staff member's user-menu tab. Derived
  # from the same unread Notification rows that drive the standard avatar
  # bell dot, so reading a mod-note from the bell decrements this count and
  # opening the shield tab (which marks the rows read) decrements the bell.
  add_to_serializer(
    :current_user,
    :mod_note_unread_count,
    include_condition: -> { DiscourseModCategories.enabled? && SiteSetting.mod_notes_feed_enabled },
  ) do
    next 0 unless object.staff?

    DiscourseModCategories::StaffNotifier.mod_notes_for(object.id).where(read: false).count
  end

  # First-post checklist: the single checklist the current user most needs
  # to accept before posting, or nil so the frontend can skip the modal.
  # The owed-checklist computation lives in
  # `DiscourseModCategories.owed_checklist_for` so the serializer and the
  # `/checklist/owed` endpoint share one implementation.
  #
  # NOTE: the bootstrapped current-user payload only carries the value as
  # of the page load. The frontend re-fetches `/checklist/owed` when the
  # composer opens so a mid-session version bump is still gated.
  add_to_serializer(:current_user, :mod_first_post_checklist) do
    DiscourseModCategories.owed_checklist_for(object)
  end

  # Per-topic reply approval: when a moderator flags a topic, replies to it
  # are routed to the review queue instead of being published directly.
  # This is the per-topic analogue of a category's require_reply_approval.
  NewPostManager.add_handler do |manager|
    next nil unless DiscourseModCategories.enabled?
    next nil unless SiteSetting.mod_topic_require_reply_approval_enabled
    topic_id = manager.args[:topic_id]
    next nil if topic_id.blank?

    topic = Topic.find_by(id: topic_id)
    next nil unless topic
    next nil unless topic.custom_fields[DiscourseModCategories::TOPIC_REQUIRE_REPLY_APPROVAL_FIELD]

    # Staff (and anyone who can review the topic) post without approval.
    next nil if manager.user&.guardian&.can_review_topic?(topic)

    manager.enqueue("mod_topic_requires_reply_approval")
  end

  # Runs before every other NewPostManager handler (and before core's own
  # approval checks): a non-staff post that answers a whisper — a reply to
  # it, or a quote of it — is marked armed, so if it ends up in the approval
  # queue the queued payload says "whisper". That keeps it out of the review
  # queue for non-staff reviewers and out of the Telegram reports chat, and
  # it is still created as a whisper once approved. Never short-circuits.
  NewPostManager.add_handler(10_000) do |manager|
    user = manager.user
    args = manager.args
    next nil if user.nil? || user.staff? || args[:topic_id].blank?

    stub =
      DiscourseModCategories::Whisper::PostStub.new(
        args[:topic_id].to_i,
        args[:reply_to_post_number],
        args[:raw],
      )
    armed_key = DiscourseModCategories::POST_WHISPER_ARMED_PARAM
    armed =
      ::ActiveModel::Type::Boolean.new.cast(DiscourseModCategories::Whisper.opt(args, armed_key))
    if armed || DiscourseModCategories::Whisper.answered_whispers(stub, {}, user).any?
      args[armed_key] = "true"
    end
    nil
  rescue StandardError => e
    Rails.logger.warn("[jtech-tools] whisper queue marker failed: #{e.class}: #{e.message}")
    nil
  end

  # Expose the per-category prompt on every serialized category so the
  # composer can read it for the category a new topic is being created in.
  #
  # reloadable_patch, not a bare registration: a dev-mode code reload
  # redefines core's Site class, whose class body RESETS the preload set —
  # a plain after_initialize registration evaporates on the first reload and
  # every page then 500s with HasCustomFields::NotPreloadedError once the
  # categories cache rebuilds. This block re-registers on every reload; the
  # target is a Set, so production's single run is unaffected.
  reloadable_patch do
    Site.preloaded_category_custom_fields << DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_FIELD
    Site.preloaded_category_custom_fields << DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD
  end
  add_to_serializer(
    :basic_category,
    :mod_category_new_topic_prompt,
    include_condition: -> do
      DiscourseModCategories.enabled? && SiteSetting.precheck_new_topic_enabled
    end,
  ) { object.custom_fields[DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_FIELD] }

  # ---------------------------------------------------------------------
  # Moderator whisper
  # ---------------------------------------------------------------------

  register_post_custom_field_type(DiscourseModCategories::POST_WHISPER_TARGETS_FIELD, :json)
  register_post_custom_field_type(DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD, :json)
  register_post_custom_field_type(DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD, :json)
  register_post_custom_field_type(DiscourseModCategories::POST_WHISPER_ADMINS_ONLY_FIELD, :boolean)
  register_topic_custom_field_type(DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD, :json)
  add_permitted_post_create_param(DiscourseModCategories::POST_WHISPER_TARGETS_FIELD, :array)
  add_permitted_post_create_param(DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD, :array)
  add_permitted_post_create_param(DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD, :array)
  # Permitted as a scalar (:string) — `add_permitted_post_create_param` only
  # special-cases :array/:hash, and an unrecognized type would drop the param
  # entirely. The value arrives as the string "true"/"false" and is cast with
  # ActiveModel::Type::Boolean in DiscourseModCategories::Whisper.prepare_new_post!.
  add_permitted_post_create_param(DiscourseModCategories::POST_WHISPER_ARMED_PARAM, :string)

  # The topic's recorded whisper participants (non-staff users staff have
  # whispered to here — they may whisper back to staff). Staff only: the list
  # says who has been whispered to, which is itself private.
  add_to_serializer(
    :topic_view,
    :mod_whisper_participant_ids,
    include_condition: -> { SiteSetting.mod_whisper_enabled && scope.is_staff? },
  ) do
    raw = object.topic.custom_fields[DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD]
    DiscourseModCategories::Whisper.normalize_ids(raw)
  end

  # Make core treat plugin whispers as whispers wherever that hides more —
  # see lib/discourse_mod_categories/core_whisper_patches.rb.
  reloadable_patch { DiscourseModCategories.apply_core_whisper_patches! }

  # A whisper that has to wait in the approval queue must still be a whisper
  # once approved — carry the arming params through the queued payload.
  allow_new_queued_post_payload_attribute(DiscourseModCategories::POST_WHISPER_ARMED_PARAM)
  allow_new_queued_post_payload_attribute(DiscourseModCategories::POST_WHISPER_TARGETS_FIELD)
  allow_new_queued_post_payload_attribute(DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD)
  allow_new_queued_post_payload_attribute(DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD)

  # Filter whispers out of the topic stream for viewers who are not in the
  # audience. Staff bypass this; the Guardian override is the parallel gate.
  # Unconditional — never gated on a setting.
  TopicView.apply_custom_default_scope do |scope, tv|
    DiscourseModCategories::WhisperQueryFilter.apply(scope, tv.guardian&.user)
  end

  # One query for the whisper fields of every post on the page, instead of
  # one per post from the Guardian and serializer checks.
  TopicView.on_preload do |topic_view|
    posts = topic_view.posts
    DiscourseModCategories::Whisper.prime!(posts.to_a) if posts.present?
  end

  # Whether a new post is a whisper (and who its audience is) is decided in
  # DiscourseModCategories::Whisper.prepare_new_post!, called from a
  # PostCreator#setup_post prepend (core_whisper_patches.rb) — NOT from the
  # :before_create_post event, which core skips whenever skip_validations is
  # set (approving a queued post, imports, some API calls).

  # Once the whisper exists: undo the public side effects core applied
  # because it is a regular post, and notify its audience. A global listener
  # (not the plugin-gated `on`), so the counter repair also runs while the
  # bundle is switched off.
  DiscourseEvent.on(:post_created) do |post, opts, user|
    topic = post.topic
    next unless topic

    next unless DiscourseModCategories::Whisper.whisper?(post)

    DiscourseModCategories::Whisper.refresh_topic_counters(topic)
    DiscourseModCategories::WhisperUnread.skip_new_whisper!(post)
    if post.reply_to_post_number.present?
      ::Topic
        .where(id: topic.id)
        .where("reply_count > 0")
        .update_all("reply_count = reply_count - 1")
    end

    next unless SiteSetting.mod_notify_whisper_targets
    next if post.instance_variable_get(:@mod_whisper_quiet)

    recipient_ids = DiscourseModCategories::Whisper.notification_recipient_ids(post)
    next if recipient_ids.empty?

    data = {
      topic_title: topic.title,
      display_username: user&.username,
      # Stable marker so MessagesController#mark_topic_notifications_seen
      # can scope its read-flip to OUR notifications without touching
      # other plugins' custom notifications attached to the same topic.
      mod_whisper: true,
      original_post_id: post.id,
      original_post_type: post.post_type,
    }.to_json

    recipient_ids.each do |recipient_id|
      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: recipient_id,
        topic_id: topic.id,
        post_number: post.post_number,
        data: data,
      )
    end
  end

  # PostAlerter (which runs after :post_created) would also send the
  # whisper's audience its usual replied / mentioned / quoted / posted
  # notifications. Anyone who already got the whisper notification above is
  # added to PostAlerter's "already notified" list, so they get one
  # notification, not two. (People outside the audience get nothing from
  # PostAlerter — its can_receive_post_notifications? check runs the
  # whisper Guardian rules.)
  DiscourseEvent.on(:post_alerter_before_mentions) do |post, _new_record, notified|
    next unless DiscourseModCategories::Whisper.whisper?(post)

    ids =
      ::Notification
        .where(
          topic_id: post.topic_id,
          post_number: post.post_number,
          notification_type: ::Notification.types[:custom],
        )
        .where("data LIKE ?", '%"mod_whisper":true%')
        .pluck(:user_id)
    next if ids.empty?

    already = notified.map(&:id)
    notified.concat(::User.where(id: ids - already).to_a)
  end

  # Whisper fields are serialized whether or not whispers are switched on:
  # existing whispers stay private either way, so they keep their banner.
  whisper_only = -> { DiscourseModCategories::Whisper.whisper?(object) }
  add_to_serializer(:post, :mod_is_whisper) { DiscourseModCategories::Whisper.whisper?(object) }

  add_to_serializer(:post, :mod_whisper_target_user_ids, include_condition: whisper_only) do
    Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD]).map(&:to_i)
  end

  add_to_serializer(:post, :mod_whisper_target_group_ids, include_condition: whisper_only) do
    Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD]).map(
      &:to_i
    )
  end

  add_to_serializer(:post, :mod_whisper_target_groups, include_condition: whisper_only) do
    ids =
      Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD]).map(
        &:to_i
      )
    ::Group.where(id: ids).map { |g| { id: g.id, name: g.name } }
  end

  add_to_serializer(:post, :mod_whisper_target_badge_ids, include_condition: whisper_only) do
    Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD]).map(
      &:to_i
    )
  end

  add_to_serializer(:post, :mod_whisper_target_badges, include_condition: whisper_only) do
    ids =
      Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD]).map(
        &:to_i
      )
    ::Badge.where(id: ids).map { |b| { id: b.id, name: b.display_name } }
  end

  add_to_serializer(:post, :mod_whisper_targets, include_condition: whisper_only) do
    ids =
      Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD]).map(&:to_i)
    ::User
      .where(id: ids)
      .map { |u| { id: u.id, username: u.username, avatar_template: u.avatar_template } }
  end

  # A whisper with no user targets AND no group targets AND no badge
  # targets is a staff-only whisper-back.
  add_to_serializer(:post, :mod_whisper_is_staff_only, include_condition: whisper_only) do
    Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGETS_FIELD]).empty? &&
      Array(
        object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_GROUPS_FIELD],
      ).empty? &&
      Array(object.custom_fields[DiscourseModCategories::POST_WHISPER_TARGET_BADGES_FIELD]).empty?
  end

  add_to_serializer(:post, :mod_whisper_author_is_staff, include_condition: whisper_only) do
    !!object.user&.staff?
  end

  # Moderators outside its targets don't see it: its banner says admins
  add_to_serializer(:post, :mod_whisper_admins_only, include_condition: whisper_only) do
    DiscourseModCategories::Whisper.admins_only?(object)
  end

  add_to_serializer(
    :basic_category,
    :mod_category_new_topic_prompt_max_tl,
    include_condition: -> do
      DiscourseModCategories.enabled? && SiteSetting.precheck_new_topic_enabled
    end,
  ) { object.custom_fields[DiscourseModCategories::CATEGORY_NEW_TOPIC_PROMPT_TL_FIELD] }

  # Audience-aware unread counts on the topic list and in read tracking —
  # see DiscourseModCategories::WhisperUnread.
  reloadable_patch do
    ::ListableTopicSerializer.prepend(DiscourseModCategories::WhisperUnread::SerializerExtension)
    ::PostTiming.singleton_class.prepend(DiscourseModCategories::WhisperUnread::PostTimingExtension)
    ::User.prepend(DiscourseModCategories::WhisperUnread::UserExtension)
  end

  # ---------------------------------------------------------------------
  # Staff event notifications
  #
  # Three event streams that fan out high-priority custom Notifications +
  # live MessageBus alerts to every other staff member, reusing the same
  # `mod_note: true` data marker the topic-note flow uses so the client
  # renderer (assets/javascripts/discourse/lib/mod-note-notification.js)
  # and the shield-tab unread counter pick them up alongside topic notes:
  #
  #   1. Post action (delete / approve queued / reject queued)
  #   2. User note added (discourse-user-notes)
  #   3. Mod note added to a flag / reviewable (ReviewableNote)
  #
  # Each is gated behind its own SiteSetting so individual streams can
  # be turned off without disabling the whole mod-categories sub-plugin.
  # ---------------------------------------------------------------------

  # 1a. Post deleted by staff. Skip self-deletes — the post author
  # destroying their own post is not a moderator action — and skip the
  # system user so automated cleanups (spam, expiry, plugin sweeps)
  # don't spam every staff member's bell.
  on(:post_destroyed) do |post, opts, user|
    next unless DiscourseModCategories.enabled?
    next unless SiteSetting.mod_notify_staff_on_post_actions
    next if post.blank? || user.blank?
    next if post.user_id == user.id
    next unless user.staff?
    system_user =
      (
        begin
          Discourse.system_user
        rescue StandardError
          nil
        end
      )
    next if system_user && user.id == system_user.id

    topic = post.topic
    begin
      DiscourseModCategories::StaffNotifier.fan_out(
        acting_user: user,
        kind: DiscourseModCategories::StaffNotifier::KIND_POST_DELETED,
        message_key: "discourse_mod_categories.post_deleted_notification",
        title_key: "discourse_mod_categories.post_deleted_notification_title",
        alert_key: "discourse_mod_categories.post_deleted_notification_alert",
        url: topic ? "#{topic.relative_url}/#{post.post_number}" : "/",
        excerpt: post.raw.to_s,
        topic: topic,
        post_number: post.post_number,
      )
    rescue StandardError => e
      # The notify side effect must never block the underlying delete.
      ::Rails.logger.warn("[jtech-tools] post_destroyed notify failed: #{e.class}: #{e.message}")
    end
  end

  # 1b/c. Queued post approved or rejected out of the review queue.
  #
  # Original implementation used `on(:approved_post)` / `on(:rejected_post)`
  # and called `reviewable.reviewed_by` to find the acting staff member,
  # but that fired BEFORE the outer Reviewable#perform set
  # reviewed_by_id, and the `reviewed_by` association is also not
  # defined on every Discourse version's ReviewableQueuedPost — calling
  # it 500'd the request. We now hook `after_update_commit` instead,
  # which fires AFTER the outer perform has set both `status` and
  # `reviewed_by_id`, and find the acting user via `reviewed_by_id`
  # with a `ReviewableHistory` fallback so it works on Discourse
  # versions where the column is absent or unset.
  # `:reviewable_transitioned_to` fires AFTER Reviewable#perform has
  # set status + reviewed_by_id and saved the record, with the status
  # passed as a symbol (`:approved`, `:rejected`, …). This is the right
  # hook — the previous attempts (`:approved_post`/`:rejected_post`
  # events + `reviewable.reviewed_by`, then `Reviewable.after_update`)
  # both failed because the inner events fire before reviewed_by_id is
  # set, and the queued-post status update path in this Discourse
  # version doesn't reliably invoke after_update callbacks.
  on(:reviewable_transitioned_to) do |status, reviewable|
    next unless DiscourseModCategories.enabled?
    next if reviewable.blank?
    # Only queued-post reviewables — flag/user reviewables transition
    # through this event too but have their own notification chain.
    next unless reviewable.type == "ReviewableQueuedPost"

    # `:approved` and `:rejected` are gated on separate settings.
    # Approvals are routine and noisy, so they have their own opt-in
    # toggle (default off) — see config/settings.yml. Rejections and
    # post deletes stay grouped under mod_notify_staff_on_post_actions.
    case status
    when :approved
      next unless SiteSetting.mod_notify_staff_on_post_approved
    when :rejected
      next unless SiteSetting.mod_notify_staff_on_post_actions
    else
      next
    end

    kind, message_key, title_key, alert_key =
      case status
      when :approved
        [
          DiscourseModCategories::StaffNotifier::KIND_POST_APPROVED,
          "discourse_mod_categories.post_approved_notification",
          "discourse_mod_categories.post_approved_notification_title",
          "discourse_mod_categories.post_approved_notification_alert",
        ]
      when :rejected
        [
          DiscourseModCategories::StaffNotifier::KIND_POST_REJECTED,
          "discourse_mod_categories.post_rejected_notification",
          "discourse_mod_categories.post_rejected_notification_title",
          "discourse_mod_categories.post_rejected_notification_alert",
        ]
      end
    next if kind.blank?

    # Acting user lookup: prefer the reviewed_by_id column (set by
    # Reviewable#perform just before save), fall back to the latest
    # history's created_by for Discourse versions where the column is
    # absent or unset.
    acting_user_id =
      (reviewable.respond_to?(:reviewed_by_id) && reviewable.reviewed_by_id) ||
        ::ReviewableHistory
          .where(reviewable_id: reviewable.id)
          .order(:created_at)
          .last
          &.created_by_id
    next if acting_user_id.blank?

    acting_user = ::User.find_by(id: acting_user_id)
    next if acting_user.blank?

    excerpt = reviewable.payload.is_a?(Hash) ? reviewable.payload["raw"].to_s : ""

    begin
      DiscourseModCategories::StaffNotifier.fan_out(
        acting_user: acting_user,
        kind: kind,
        message_key: message_key,
        title_key: title_key,
        alert_key: alert_key,
        url: "/review/#{reviewable.id}",
        excerpt: excerpt,
        reviewable: reviewable,
      )
    rescue StandardError => e
      ::Rails.logger.warn(
        "[jtech-tools] reviewable transition notify (#{kind}) failed: #{e.class}: #{e.message}",
      )
    end
  end

  # 2. User note added on a user's profile via the bundled
  # discourse-user-notes plugin. That plugin's `::DiscourseUserNotes
  # .add_note(user, raw, created_by_id, opts)` writes a Hash into the
  # PluginStore and does NOT fire any DiscourseEvent, so wrap it with
  # an alias and fan out from the wrapper. Skipped when the bundled
  # plugin isn't loaded (e.g. disabled in development).
  reloadable_patch do
    if defined?(::DiscourseUserNotes) && ::DiscourseUserNotes.respond_to?(:add_note)
      ::DiscourseUserNotes.singleton_class.class_eval do
        unless method_defined?(:add_note_without_mod_categories_notify) ||
                 private_method_defined?(:add_note_without_mod_categories_notify)
          alias_method :add_note_without_mod_categories_notify, :add_note

          # Pass-through signature (positional + keyword) so a future
          # Discourse refactor of add_note's arity doesn't break the
          # wrapper — the notifier path is purely additive and wrapped
          # in rescue StandardError, so a malformed call still saves
          # the note via the original method.
          define_method(:add_note) do |*args, **kwargs|
            note = add_note_without_mod_categories_notify(*args, **kwargs)

            begin
              if DiscourseModCategories.enabled? && SiteSetting.mod_notify_staff_on_user_notes
                user = args[0]
                raw = args[1]
                created_by_id = args[2]
                acting_user = ::User.find_by(id: created_by_id)
                if acting_user && user.respond_to?(:username)
                  ::DiscourseModCategories::StaffNotifier.fan_out(
                    acting_user: acting_user,
                    kind: ::DiscourseModCategories::StaffNotifier::KIND_USER_NOTE,
                    message_key: "discourse_mod_categories.user_note_notification",
                    title_key: "discourse_mod_categories.user_note_notification_title",
                    alert_key: "discourse_mod_categories.user_note_notification_alert",
                    url: "/u/#{user.username}/notes",
                    excerpt: raw.to_s,
                    target_username: user.username,
                  )
                end
              end
            rescue StandardError => e
              ::Rails.logger.warn(
                "[jtech-tools] user_note staff notify failed: #{e.class}: #{e.message}",
              )
            end

            note
          end
        end
      end
    end
  end

  # 3. Moderator note added to a flag / reviewable in the review queue.
  # ReviewableNote is the AR model that backs the "Add a note" textarea
  # on a reviewable's detail panel — created via the core
  # Reviewables::NotesController. It has no DiscourseEvent, so hook
  # after_create directly. Using after_create (not _commit) so the
  # callback fires inside the request's transaction and is observable
  # from request specs with transactional fixtures. The downside —
  # firing the notification when a creating transaction is later
  # rolled back — is acceptable because the controller commits the row
  # before returning a successful response. add_model_callback keeps
  # dev-mode reloads from piling up duplicate callbacks and skips the hook
  # while the plugin is off.
  add_model_callback("ReviewableNote", :after_create) do
    next unless DiscourseModCategories.enabled?
    next unless SiteSetting.mod_notify_staff_on_flag_notes

    author = ::User.find_by(id: user_id)
    reviewable = ::Reviewable.find_by(id: reviewable_id)
    next if author.blank? || reviewable.blank?

    target_user = reviewable.target_created_by
    target_label = target_user&.username || reviewable.type.to_s.sub(/^Reviewable/, "")

    begin
      DiscourseModCategories::StaffNotifier.fan_out(
        acting_user: author,
        kind: DiscourseModCategories::StaffNotifier::KIND_FLAG_NOTE,
        message_key: "discourse_mod_categories.flag_note_notification",
        title_key: "discourse_mod_categories.flag_note_notification_title",
        alert_key: "discourse_mod_categories.flag_note_notification_alert",
        url: "/review/#{reviewable.id}",
        excerpt: content.to_s,
        reviewable: reviewable,
        target_username: target_label,
      )
    rescue StandardError => e
      ::Rails.logger.warn("[jtech-tools] flag_note notify failed: #{e.class}: #{e.message}")
    end
  end

  # ---------------------------------------------------------------------
  # Whisper visibility — surfaces beyond the topic stream
  # ---------------------------------------------------------------------

  # 1. /u/{username}/activity feed. UserAction.stream builds the activity
  # rows from raw SQL joined to posts/topics, so a whisper post the viewer
  # cannot read still surfaces in another user's profile (the "replied to
  # topic X" row stays, even though Guardian#can_see_post? would block the
  # post itself). We wrap UserAction.stream to post-filter the result
  # against the same audience rules WhisperQueryFilter enforces on the
  # topic stream — non-staff non-audience viewers stop seeing the row at
  # all. Anonymous viewers see no whispers either. Page size becomes
  # approximate (a 30-row page may render fewer rows when some were
  # whispers), which is acceptable; the next-page link is unchanged so
  # navigation still works. `rescue StandardError` falls back to the
  # unfiltered result if a future Discourse refactor reshapes the row
  # objects, so /u/{user}/activity can't 500.
  reloadable_patch do
    module ::DiscourseModCategories
      module UserActionStreamWhisperFilterPatch
        def stream(opts = nil)
          rows = super
          return rows if rows.blank?

          guardian = opts.is_a?(Hash) ? opts[:guardian] : nil
          viewer = guardian.respond_to?(:user) ? guardian.user : nil

          DiscourseModCategories::UserActionWhisperFilter.apply(rows, viewer)
        end
      end
    end

    ::UserAction.singleton_class.prepend(
      ::DiscourseModCategories::UserActionStreamWhisperFilterPatch,
    )
  end

  # 2. Live sidebar / category unread counters. TopicTrackingState publishes
  # MessageBus updates when ANY post is created, including whispers — the
  # payload carries the post's own post_number, so every subscribed client
  # (audience or not) bumps its in-memory unread count for the topic and
  # the count flows into the sidebar/category badge. The DB rollback above
  # only fixes page-refresh state; the live update needs filtering at the
  # subscriber list. `:topic_tracking_state_publish_unread_scope` is the
  # documented hook — Discourse passes us the TopicUser scope and the post,
  # and we narrow it to audience-only when the post is one of OUR whispers.
  register_modifier(:topic_tracking_state_publish_unread_scope) do |scope, post|
    begin
      next scope unless post.is_a?(::Post)
      audience_ids = DiscourseModCategories::Whisper.audience_user_ids(post)
      next scope if audience_ids.nil?

      scope.where(user_id: audience_ids)
    rescue StandardError => e
      # Fail CLOSED: nobody gets a live unread bump rather than everybody.
      ::Rails.logger.warn(
        "[jtech-tools] tracking-state whisper filter failed: #{e.class}: #{e.message}",
      )
      scope.none
    end
  end

  # 3. Full-text search leaked whisper text to non-audience users. Discourse's
  # `SearchIndexer` writes every post's tsvector into `post_search_data`, and
  # `Search#execute` runs `ts_query` against that table BEFORE any per-user
  # visibility check. So a whisper's raw contents were discoverable via
  # `/search?q=<word from whisper>` — including through the `is:unseen`
  # advanced filter, which shortcuts around Guardian by hitting the index
  # directly. Two-layer fix, DB-level primary:
  #
  #   (a) `SearchIndexer` gate — skip whisper posts during indexing AND delete
  #       any existing row. The whisper never sits in `post_search_data`, so
  #       no tsquery can match it and no advanced filter can reach it.
  #   (b) `Search#execute` post-filter — belt-and-suspenders. If a row
  #       survives the indexer gate (race, backfill pending, custom field
  #       written after first index write), the result-set filter still
  #       drops it before serialization.
  #
  # The migration `20260701000001_purge_whisper_post_search_data.rb` runs the
  # backfill: one SQL DELETE that strips every already-indexed whisper on
  # deploy so the leak stops without waiting for each post to be re-touched.
  reloadable_patch do
    ::SearchIndexer.singleton_class.prepend(::DiscourseModCategories::SearchIndexerExtension)
    ::Search.prepend(::DiscourseModCategories::SearchExtension) if defined?(::Search)
  end

  # When staff convert a whisper → public via update_post_whisper (disarm),
  # the whisper custom field is removed, so the SearchIndexer gate would
  # now let the post through — but nothing triggers a re-index by default.
  # Force one so the newly-public post becomes discoverable.
  #
  # The inverse (public → whisper) is handled by the gate itself: the next
  # `SearchIndexer.index` call for that post_id will delete its row, and
  # we also fire one explicitly here to close the window between the arm
  # and the next natural re-index (post edit, cook, etc.).
  DiscourseEvent.on(:mod_whisper_state_changed) do |post, armed|
    next unless post.is_a?(::Post)

    begin
      if armed
        ::PostSearchData.where(post_id: post.id).delete_all
        # Links inside the post feed the public topic map ("links" in the
        # topic summary); a whisper's links are as private as its text.
        ::TopicLink.where(post_id: post.id).delete_all
        topic = post.topic
        if topic
          # A pinned copy renders the post's cooked HTML for every viewer.
          pinned_id = topic.custom_fields[DiscourseModCategories::TOPIC_PINNED_POST_FIELD]
          if pinned_id.to_i == post.id
            topic.custom_fields.delete(DiscourseModCategories::TOPIC_PINNED_POST_FIELD)
            topic.save_custom_fields(true)
          end
          DiscourseModCategories::Whisper.refresh_topic_counters(topic)
          # It bumped the topic while it was public; the bump goes back to
          # the last post everyone can see.
          topic.reset_bumped_at if (topic.bumped_at - post.created_at).abs < 1.second
        end
        # Other posts may carry a baked link preview of this post.
        DiscourseModCategories::Whisper.rebake_linking_posts(post)
        # The Telegram bridge may already have mirrored it while public.
        ::Jobs.enqueue(:disteleplus_retract_whisper, post_id: post.id)
      else
        ::SearchIndexer.index(post, force: true)
        ::TopicLink.extract_from(post)
        ::Topic.reset_highest(post.topic_id) if post.topic_id
        # Public again, it bumps the topic as it would have when posted. The
        # bump comes from the last post core would bump to, so one a flag
        # hides or its author withdrew waits until it's back.
        topic = post.topic&.reload
        topic.reset_bumped_at if topic && topic.bumped_at < post.created_at
      end
      DiscourseModCategories::Whisper.refresh_reply_counts(
        ::PostReply.where(reply_post_id: post.id).pluck(:post_id),
      )
    rescue StandardError => e
      ::Rails.logger.warn(
        "[jtech-tools] whisper state side effects failed for post=#{post.id}: " \
          "#{e.class}: #{e.message}",
      )
    end
  end

  # 4. Second filter dropdown on /u/{username}/notifications. The frontend
  # initializer (assets/javascripts/discourse/initializers/notifications-type-filter.js)
  # sends ?type=<value>. Two cases:
  #   - "mod_notes": needs a JSON-column LIKE filter, so we render the list
  #     ourselves. Gated to staff — non-staff silently get the unfiltered
  #     index so the URL can't leak staff-only data.
  #   - Any built-in Discourse notification type name: translate into the
  #     existing filter_by_types param so Discourse's index handler does
  #     the rest, keeping us forward-compatible with its query logic.
  reloadable_patch do
    module ::DiscourseModCategories
      module NotificationsControllerTypeFilter
        def index
          return super unless SiteSetting.jtech_enabled
          return super unless SiteSetting.mod_notification_type_filter_enabled

          requested_type = params[:type].to_s.strip
          return super if requested_type.blank? || requested_type == "all"

          if requested_type == "mod_notes"
            unless guardian.is_staff?
              params.delete(:type)
              return super
            end
            return render_mod_notes_index
          end

          # Standard notification types. Core Discourse's
          # NotificationsController#index only honours `filter_by_types`
          # on the `?recent=true` branch (the user-menu dropdown). The
          # /u/{username}/notifications page falls into the `else`
          # branch — which fetches `Notification.where(user_id: ...).
          # visible` and ignores type filters entirely. So even when the
          # client sent `?filter_by_types=replied`, Discourse returned
          # the unfiltered list and the visible page wasn't narrowed.
          # We have to render the filtered index ourselves, mirroring
          # the shape `render_mod_notes_index` uses below.
          #
          # Case-insensitive match — `Notification.types` keys are
          # lowercase snake_case symbols, but a hand-typed URL may
          # capitalize the value (`?type=Boost` rather than `?type=boost`).
          # Fall through to super on a casing miss so a typo doesn't 500.
          canonical_type =
            ::Notification.types.keys.find { |k| k.to_s.casecmp(requested_type).zero? }
          return super unless canonical_type

          render_type_filtered_index(canonical_type)
        end

        private

        # The user whose notifications are being listed, with core's own
        # permission check (self or admin). Without it any signed-in user
        # could read anyone's notifications through ?username=…&type=….
        def mod_notifications_user
          user =
            if params[:username].present?
              ::User.find_by(username_lower: params[:username].to_s.downcase)
            else
              current_user
            end
          raise Discourse::NotFound unless user
          guardian.ensure_can_see_notifications!(user)
          user
        end

        # Mirrors the response shape of NotificationsController#index's
        # paginated branch (see discourse/discourse:app/controllers/
        # notifications_controller.rb) exactly — the Ember store.find
        # adapter expects all four keys and the user-notifications page's
        # load-more behaviour reads `load_more_notifications`. Returning
        # only `{ notifications, total_rows_notifications }` was leaving
        # the list empty in the JS layer.
        # Per-notification-type counterpart to render_mod_notes_index. The
        # core /u/{username}/notifications JSON endpoint silently ignores
        # `filter_by_types` outside of the `?recent=true` branch, so the
        # type filter needs to be applied here. Same response envelope
        # the user-notifications template binds against.
        def render_type_filtered_index(type_sym)
          render_filtered_index(type_sym.to_s) do |user|
            ::Notification.where(
              user_id: user.id,
              notification_type: ::Notification.types[type_sym],
            )
          end
        end

        def render_mod_notes_index
          render_filtered_index("mod_notes") do |user|
            DiscourseModCategories::StaffNotifier.mod_notes_for(user.id)
          end
        end

        # The bell's list, narrowed to the notifications the block picks for
        # the user (the one whose notifications are shown).
        def render_filtered_index(type)
          user = mod_notifications_user
          limit = 60
          offset = params[:offset].to_i
          scope = yield(user).visible.includes(:topic).order(created_at: :desc)

          scope = scope.where(read: true) if params[:filter] == "read"
          scope = scope.where(read: false) if params[:filter] == "unread"

          total = scope.dup.count
          notifications = scope.offset(offset).limit(limit)
          notifications =
            ::Notification.filter_inaccessible_topic_notifications(
              current_user.guardian,
              notifications,
            )
          notifications = ::Notification.filter_disabled_badge_notifications(notifications)
          notifications = ::Notification.populate_acting_user(notifications)

          render_json_dump(
            notifications: serialize_data(notifications, ::NotificationSerializer),
            total_rows_notifications: total,
            seen_notification_id: user.seen_notification_id,
            load_more_notifications:
              notifications_path(
                username: user.username,
                offset: offset + limit,
                limit: limit,
                filter: params[:filter],
                type: type,
              ),
          )
        end
      end
    end

    ::NotificationsController.prepend(::DiscourseModCategories::NotificationsControllerTypeFilter)
  end
end
