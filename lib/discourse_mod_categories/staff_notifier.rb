# frozen_string_literal: true

module ::DiscourseModCategories
  # Shared fan-out of high-priority custom Notifications + live MessageBus
  # alerts to every other staff member. Used for the three "staff event"
  # streams that are NOT topic-attached private notes:
  #   - actions on a post (delete / approve queued / reject queued)
  #   - notes added on a user's profile (discourse-user-notes)
  #   - notes added to a flag / reviewable in the review queue
  #
  # The notification carries the same `mod_note: true` marker the topic-
  # note flow uses, so the existing client renderer
  # (assets/javascripts/discourse/lib/mod-note-notification.js) and the
  # shield-tab unread counter pick these up alongside topic notes. The
  # `mod_note_kind` field tells the renderer which label/title to show.
  module StaffNotifier
    KIND_POST_DELETED = "post_deleted"
    KIND_POST_APPROVED = "post_approved"
    KIND_POST_REJECTED = "post_rejected"
    KIND_USER_NOTE = "user_note"
    KIND_FLAG_NOTE = "flag_note"

    # A user's notifications from the mod notes feed: topic notes and
    # replies, and the staff events above.
    def self.mod_notes_for(user_id)
      ::Notification.where(
        user_id: user_id,
        notification_type: ::Notification.types[:custom],
      ).where("data LIKE ?", '%"mod_note":true%')
    end

    # `acting_user` is excluded from recipients so the moderator who
    # performed the action does not get their own notification.
    #
    # The entire method body is wrapped in `rescue StandardError` so the
    # underlying moderator action (the post delete, the queued-post
    # approve, the ReviewableNote insert, the user-note save) NEVER 500s
    # because the staff fan-out had a problem. Notifications are
    # best-effort by design; the user's action must succeed regardless.
    # The rescue is intentionally swallowing — a broken notifier should
    # log and let the request return 2xx, not bubble out to the
    # controller. Specs in spec/requests/staff_event_integration_spec.rb
    # exercise this contract by injecting `fan_out` raises and asserting
    # the user's endpoint still returns success.
    # Staff members other than `except` who may see what the alert is
    # about. Moderators don't see every private message, every restricted
    # category or every review item (some are admin-only), and an alert
    # carries the title and an excerpt — so it goes only to staff who could
    # open the thing it points at.
    def self.staff_recipients(except:, topic: nil, reviewable: nil)
      staff = ::User.where(admin: true).or(::User.where(moderator: true))
      staff = staff.where.not(id: except.id) if except

      Enumerator.new do |yielder|
        staff.find_each do |staff_user|
          next if topic && !::Guardian.new(staff_user).can_see_topic?(topic)
          if reviewable && !::Reviewable.viewable_by(staff_user).where(id: reviewable.id).exists?
            next
          end
          yielder << staff_user
        end
      end
    end

    def self.fan_out(
      acting_user:,
      kind:,
      message_key:,
      title_key:,
      alert_key:,
      url:,
      excerpt: nil,
      topic: nil,
      reviewable: nil,
      post_number: nil,
      target_username: nil
    )
      return if acting_user.blank?

      acting_username = acting_user.username
      truncated_excerpt = excerpt.to_s.truncate(300)
      topic_id = topic&.id
      topic_title = topic&.title

      staff_recipients(
        except: acting_user,
        topic: topic,
        reviewable: reviewable,
      ).each do |staff_user|
        # Idempotency check: skip when this staff member already has a
        # mod-note notification of the same kind anchored on the same
        # target (topic+post for topic-anchored kinds, URL for review/
        # user-notes kinds) created in the last 30 seconds. Protects
        # against the event hook firing twice in quick succession
        # (event-bus retry, a future Discourse refactor calling the
        # event twice, race with another plugin) without suppressing
        # the legitimate "moderator added two real notes in a row"
        # case, which still creates distinct rows because the second
        # is anchored on a different reply_id / different note row.
        if recent_duplicate?(
             staff_user: staff_user,
             kind: kind,
             topic_id: topic_id,
             post_number: post_number,
             url: url,
           )
          next
        end

        data = {
          display_username: acting_username,
          mod_note: true,
          mod_note_kind: kind,
          excerpt: truncated_excerpt,
          url: url,
          message: message_key,
          title: title_key,
        }
        data[:topic_title] = topic_title if topic_title.present?
        data[:target_username] = target_username if target_username.present?

        ::Notification.create!(
          notification_type: ::Notification.types[:custom],
          user_id: staff_user.id,
          topic_id: topic_id,
          post_number: post_number,
          high_priority: true,
          data: data.to_json,
        )

        publish_alert(
          staff_user,
          alert_key: alert_key,
          url: url,
          excerpt: truncated_excerpt,
          username: acting_username,
          topic_id: topic_id,
          post_number: post_number,
          topic_title: topic_title,
          target_username: target_username,
        )
        staff_user.publish_notifications_state
      end
    rescue StandardError => e
      ::Rails.logger.warn(
        "[jtech-tools] staff_notifier fan_out (#{kind}) failed: #{e.class}: #{e.message}",
      )
      nil
    end

    def self.publish_alert(
      staff_user,
      alert_key:,
      url:,
      excerpt:,
      username:,
      topic_id:,
      post_number:,
      topic_title:,
      target_username:
    )
      return if staff_user.suspended?

      i18n_args = { username: username }
      i18n_args[:topic] = topic_title if topic_title.present?
      i18n_args[:target] = target_username if target_username.present?

      payload = {
        notification_type: ::Notification.types[:custom],
        topic_id: topic_id,
        post_number: post_number,
        excerpt: excerpt,
        username: username,
        post_url: url,
        translated_title: ::I18n.t(alert_key, **i18n_args),
      }
      payload[:topic_title] = topic_title if topic_title.present?

      # In-tab live alert (only fires for users with a live connection).
      if staff_user.allow_live_notifications?
        ::MessageBus.publish(
          "/notification-alert/#{staff_user.id}",
          payload,
          user_ids: [staff_user.id],
        )
      end

      # Web Push (enqueued — fires even when the tab is closed/backgrounded,
      # which is the whole reason a Firefox mod was missing these). Reuses
      # core PostAlerter.push_notification so we inherit its full gate
      # stack: do-not-disturb, plugin push_notification_filters, the
      # subscription-existence check, the push_notification_time_window
      # delay, and the :push_notification DiscourseEvent. Without this
      # call the staff-event notifications only deliver in-tab via the
      # MessageBus path above and never reach a closed browser.
      if defined?(::PostAlerter)
        begin
          ::PostAlerter.push_notification(staff_user, payload)
        rescue StandardError => e
          ::Rails.logger.warn(
            "[jtech-tools] staff_notifier push enqueue failed: #{e.class}: #{e.message}",
          )
        end
      end
    end

    # True when an identical-target mod_note notification was already
    # created for this staff user in the last 30 seconds. The data-
    # column LIKE filter is stable enough because the JSON keys are
    # written in a fixed order by `to_json` on a literal hash. Failure
    # to find a match falls through to creating a fresh row — dedup
    # MUST be conservative so legitimate distinct events still surface.
    def self.recent_duplicate?(staff_user:, kind:, topic_id:, post_number:, url:)
      scope =
        ::Notification
          .where(user_id: staff_user.id, notification_type: ::Notification.types[:custom])
          .where("created_at > ?", 30.seconds.ago)
          .where("data LIKE ?", "%\"mod_note_kind\":\"#{kind}\"%")

      if topic_id
        scope = scope.where(topic_id: topic_id)
        scope = scope.where(post_number: post_number) if post_number
      elsif url.present?
        # Escape `%` and `_` in the URL so a target id like "1_2" can't
        # match an unrelated URL with the wildcard semantics of LIKE.
        safe_url = url.to_s.gsub("\\", "\\\\\\\\").gsub("%", '\\%').gsub("_", '\\_')
        scope = scope.where("data LIKE ?", "%\"url\":\"#{safe_url}\"%")
      end

      scope.exists?
    rescue StandardError => e
      ::Rails.logger.warn(
        "[jtech-tools] staff_notifier recent_duplicate? check failed: #{e.class}: #{e.message}",
      )
      false
    end
  end
end
