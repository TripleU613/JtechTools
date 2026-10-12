import type Owner from "@ember/owner";
import { ajax } from "discourse/lib/ajax";
import { withPluginApi } from "discourse/lib/plugin-api";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type SiteSettings from "discourse/services/site-settings";

const TOPIC_URL_RE = /^\/t\/[^/]+\/(\d+)(?:\/\d+)?\/?$/;

interface TopicNotificationsSiteSettings {
  mod_auto_mark_notifications_seen: boolean;
}

// Unread notifications by type id: all of them, not just the unseen ones.
// Core keeps it current from the notification channel.
type UnreadUser = User & {
  grouped_unread_notifications?: Record<number, number>;
};

// Marks the current user's custom mod-note + mod-whisper notifications
// for the topic they just opened as read. Discourse's built-in
// auto-mark-read only covers a hardcoded list of notification types
// and skips `custom`, so plugin notifications about a topic would sit
// unread in the bell forever even after the user opened the topic.
//
// Triggered on every page-change to a /t/<slug>/<id>[/<post_number>]
// URL. The backend filter pins this to OUR custom notifications only,
// so we don't touch notifications another plugin might attach to the
// same topic.
export default {
  name: "discourse-mod-topic-notifications-clear",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & TopicNotificationsSiteSettings;
    if (!siteSettings.mod_auto_mark_notifications_seen) {
      return;
    }
    const site = container.lookup("service:site") as Site & {
      notification_types?: Record<string, number>;
    };
    const customType = site.notification_types?.custom;

    withPluginApi((api) => {
      const currentUser: UnreadUser | null = api.getCurrentUser();
      if (!currentUser) {
        return;
      }

      api.onPageChange((url: unknown) => {
        if (typeof url !== "string") {
          return;
        }
        const match = url.match(TOPIC_URL_RE);
        if (!match) {
          return;
        }
        // Most topic opens have nothing to clear: skip the request when
        // there isn't a single unread custom notification.
        const unread = currentUser.grouped_unread_notifications;
        if (unread && customType !== undefined && !unread[customType]) {
          return;
        }
        const topicId = match[1];
        ajax(`/discourse-mod-categories/topic/${topicId}/notifications/seen`, {
          type: "POST",
        }).catch(() => {
          // Silent — marking-read on topic open is best-effort. A
          // failure here just means the notification stays unread,
          // which is the pre-fix state.
        });
      });
    });
  },
};
