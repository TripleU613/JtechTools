# frozen_string_literal: true

module DiscourseReqpm
  # Bell notifications for REQ-PM. They carry who and what happened — never
  # a contact value — and link to the REQ-PM page, which is the only place
  # details are shown.
  #
  # Uses the `custom` notification type like the plugin's other features;
  # the shared client renderer (lib/mod-note-notification.js) picks these up
  # by the `reqpm` marker in data.
  module Notifier
    KINDS = %w[request shared].freeze
    PAGE = "/reqpm"

    def self.request_created(request)
      notify(
        user: request.target,
        actor: request.requester,
        kind: "request",
        url: "#{PAGE}?tab=requests",
        extra: {
          reqpm_request_id: request.id,
        },
      )
    end

    def self.shared(owner:, recipient:)
      notify(
        user: recipient,
        actor: owner,
        kind: "shared",
        url: "#{PAGE}?tab=contacts&user=#{owner.username}",
      )
    end

    # Unread REQ-PM notifications `user` has from `actor` of `kind`: one row
    # per (actor, kind) is enough, so a new one replaces the old.
    def self.unread_for(user_id:, actor_id:, kind:)
      Notification
        .where(user_id: user_id, notification_type: Notification.types[:custom], read: false)
        .order(id: :desc)
        .limit(200)
        .select do |n|
          data = parse(n.data)
          data["reqpm"] && data["reqpm_kind"] == kind && data["reqpm_actor_id"] == actor_id
        end
    end

    def self.remove(user:, actor_id:, kind:)
      ids = unread_for(user_id: user.id, actor_id: actor_id, kind: kind).map(&:id)
      return if ids.empty?
      Notification.where(id: ids).delete_all
      user.publish_notifications_state
    end

    def self.mark_read(user:, actor_id:, kind:)
      ids = unread_for(user_id: user.id, actor_id: actor_id, kind: kind).map(&:id)
      return if ids.empty?
      Notification.where(id: ids).update_all(read: true)
      user.publish_notifications_state
    end

    def self.notify(user:, actor:, kind:, url:, extra: {})
      raise ArgumentError, "unknown kind #{kind}" if KINDS.exclude?(kind)
      remove(user: user, actor_id: actor.id, kind: kind)

      Notification.create!(
        notification_type: Notification.types[:custom],
        user_id: user.id,
        high_priority: kind == "request",
        data: {
          reqpm: true,
          reqpm_kind: kind,
          reqpm_actor_id: actor.id,
          message: "reqpm.notifications.#{kind}",
          title: "reqpm.title",
          url: url,
          username: actor.username,
          display_username: actor.username,
          avatar_template: actor.avatar_template,
          # Second line of the desktop pop-up card.
          excerpt: I18n.t("reqpm.notifications.#{kind}"),
        }.merge(extra).to_json,
      )
    end

    def self.parse(raw)
      JSON.parse(raw.presence || "{}")
    rescue JSON::ParserError
      {}
    end
  end
end
