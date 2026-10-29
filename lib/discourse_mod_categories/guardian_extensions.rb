# frozen_string_literal: true

module DiscourseModCategories
  module GuardianExtensions
    # Moderator category management is core's own setting,
    # moderators_manage_categories (create, edit and delete categories they
    # can see). This module used to grant it without the visibility check,
    # so moderators could open and re-permission admin-only categories.

    # Whether the current user may set the plugin's moderator messages
    # (per-topic footer, per-topic reply prompt). Admins always may;
    # moderators may while the plugin is enabled. Regular users never may.
    def can_manage_mod_messages?
      return true if is_admin?
      mod_categories_grant?
    end

    # A whisper post is one that carries the POST_WHISPER_TARGETS_FIELD custom
    # field — KEY PRESENCE marks it, even an empty `[]` array. It is visible
    # only to its audience (staff, the author, its explicit user targets and
    # current members/holders of its target groups/badges); see
    # DiscourseModCategories::Whisper. Enforced regardless of any toggle:
    # switching whispers off must never make existing whispers public.
    def can_see_post?(post)
      if post.is_a?(::Post) &&
           !DiscourseModCategories::Whisper.visible_to?(post, mod_whisper_viewer)
        return false
      end
      super
    end

    # Core has post-level permissions that do NOT route through
    # can_see_post? — e.g. can_view_edit_history? returns true for any
    # post while `edit_history_visible_to_public` is on (the default), and
    # can_edit_post? lets category group moderators / edit_all_post_groups /
    # wiki editors in without a visibility check. Every one of them must be
    # false for a whisper the user cannot see, so no endpoint can hand back
    # a whisper's raw, cooked or revision history as a side effect.
    WHISPER_GATED_POST_PERMISSIONS = %i[
      can_edit_post?
      can_delete_post?
      can_delete_post_or_topic?
      can_permanently_delete_post?
      can_recover_post?
      can_lock_post?
      can_wiki?
      can_view_edit_history?
      can_view_raw_email?
      can_unhide?
      can_receive_post_notifications?
      can_review_post?
    ].freeze

    WHISPER_GATED_POST_PERMISSIONS.each do |name|
      define_method(name) do |post, *args, **kwargs, &blk|
        if post.is_a?(::Post) &&
             !DiscourseModCategories::Whisper.visible_to?(post, mod_whisper_viewer)
          return false
        end
        super(post, *args, **kwargs, &blk)
      end
    end

    def post_can_act?(post, action_key, opts: {}, can_see_post: nil)
      if post.is_a?(::Post) &&
           !DiscourseModCategories::Whisper.visible_to?(post, mod_whisper_viewer)
        return false
      end
      super
    end

    # Revisions of a whisper are as private as the whisper itself.
    def can_see_post_revision?(post_revision)
      post = post_revision&.post
      if post.is_a?(::Post) &&
           !DiscourseModCategories::Whisper.visible_to?(post, mod_whisper_viewer)
        return false
      end
      super
    end

    # Whether the current user may post a whisper in the given topic. Staff
    # always may; a non-staff user may only if they are a recorded whisper
    # participant of the topic (staff whispered to them there before). A
    # non-staff whisper is never wider than the whisper it answers — see the
    # creation logic (Whisper.prepare_new_post!).
    def can_whisper_in_topic?(topic)
      return false unless SiteSetting.mod_whisper_enabled
      return false unless authenticated?
      return true if is_staff?

      mod_whisper_participant_ids(topic).include?(@user.id)
    end

    # Whether the current user may put `user` in slow mode, or lift it. The
    # same people core lets silence them (staff, never on staff), with
    # moderators behind their own switch.
    def can_set_user_slow_mode?(user)
      return false unless DiscourseModCategories::UserSlowMode.enabled?
      return false if user.nil? || user.staff? || user.bot?
      return true if is_admin?
      is_moderator? && SiteSetting.mod_user_slow_mode_moderators
    end

    private

    # Guardian keeps a placeholder AnonymousUser in @user for logged-out
    # viewers; the whisper rules want nil for "nobody".
    def mod_whisper_viewer
      authenticated? ? @user : nil
    end

    def mod_whisper_participant_ids(topic)
      return [] unless topic

      raw = topic.custom_fields[DiscourseModCategories::TOPIC_WHISPER_PARTICIPANTS_FIELD]
      DiscourseModCategories::Whisper.normalize_ids(raw)
    end

    def mod_categories_grant?
      DiscourseModCategories.enabled? && is_moderator?
    end
  end
end
