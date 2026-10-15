import type BaseNotificationType from "discourse/lib/notification-types/base";
import { i18n } from "discourse-i18n";

// Notification-type renderer for the moderator-note custom notification
// AND the staff-event streams that piggyback on the same `mod_note: true`
// marker (post actions, user notes, flag/reviewable notes). Core allows one
// renderer per notification type, so the other features' `custom`
// notifications (Disteleplus mentions, REQ-PM, Mod elections) are decoded
// here too.
//
// All plugin notifications share the `custom` notification type, so this
// renderer keys off the `mod_note` marker the server sets in the
// notification `data`. When the marker is absent (e.g. a whisper
// notification, also `custom`) every getter reproduces core's default
// `custom` notification behavior so other custom notifications are
// untouched. Registering a `custom` renderer replaces core's `custom.js`,
// so its `icon`/`linkTitle` logic is mirrored here for the fallback.

// Maps `mod_note_kind` → translation-key suffix in the
// `discourse_mod_categories` namespace. Falls back to "note" for both
// legacy rows (set before `mod_note_kind` existed) and any unknown
// future kind, so older rows always render as the original mod note.
const KIND_KEYS: Record<string, string> = {
  note: "note_notification",
  reply: "note_reply_notification",
  post_deleted: "post_deleted_notification",
  post_approved: "post_approved_notification",
  post_rejected: "post_rejected_notification",
  user_note: "user_note_notification",
  flag_note: "flag_note_notification",
};

// The `data` keys this renderer reads off a `custom` notification.
interface ModNoteNotificationData {
  mod_note?: boolean;
  mod_note_kind?: string;
  disteleplus?: boolean;
  disteleplus_kind?: string;
  reqpm?: boolean;
  reqpm_kind?: string;
  mod_election?: boolean;
  mod_election_kind?: string;
  url?: string;
  title?: string;
  mod_whisper?: boolean;
  message?: string;
  excerpt?: string;
  topic_title?: string;
}

interface ModNoteNotification {
  data?: ModNoteNotificationData;
}

export default function modNoteNotificationRenderer(
  NotificationTypeBase: typeof BaseNotificationType
) {
  return class extends NotificationTypeBase {
    declare notification: ModNoteNotification;

    get isModNote(): boolean {
      return !!this.notification.data?.mod_note;
    }

    // Disteleplus conversation mentions share the `custom` type; they carry
    // the message text in data.excerpt and a #m deep link in data.url.
    get isDisteleplus(): boolean {
      return !!this.notification.data?.disteleplus;
    }

    // REQ-PM: someone asked for, or sent, contact details. The data holds
    // only who and what — never a contact value.
    get isReqpm(): boolean {
      return !!this.notification.data?.reqpm;
    }

    // Mod elections: a step of the election, from the system rather than a
    // person.
    get isModElection(): boolean {
      return !!this.notification.data?.mod_election;
    }

    get reqpmKind(): "shared" | "request" {
      return this.notification.data?.reqpm_kind === "shared"
        ? "shared"
        : "request";
    }

    // "mention" (default) or "poll_closed" — each gets its own bell text.
    get disteleplusKind(): string {
      return this.notification.data?.disteleplus_kind || "mention";
    }

    // "note" (default) vs "reply" / "post_deleted" / "post_approved" /
    // "post_rejected" / "user_note" / "flag_note" — every kind gets its
    // own label/title so the bell row reads accurately. Pre-`mod_note_kind`
    // rows (set before this field existed) are treated as the original note.
    get modNoteKind(): string {
      return this.notification.data?.mod_note_kind || "note";
    }

    get modNoteKey(): string {
      return KIND_KEYS[this.modNoteKind] || KIND_KEYS.note;
    }

    // Link straight to the target — note anchor on a topic, the post,
    // the user notes tab, or the review-queue entry, depending on kind.
    get linkHref(): string {
      if (
        (this.isModNote ||
          this.isDisteleplus ||
          this.isReqpm ||
          this.isModElection) &&
        this.notification.data?.url
      ) {
        return this.notification.data.url;
      }
      return super.linkHref;
    }

    get linkTitle(): string {
      if (this.isModElection) {
        return i18n("mod_elections.title");
      }
      if (this.isReqpm) {
        return i18n("reqpm.title");
      }
      if (this.isDisteleplus) {
        if (this.disteleplusKind === "poll_closed") {
          return i18n("disteleplus.poll.closed_title");
        }
        return i18n("disteleplus.mention_title");
      }
      if (this.isModNote) {
        return i18n(`discourse_mod_categories.${this.modNoteKey}_title`);
      }
      if (this.notification.data?.mod_whisper) {
        return i18n("discourse_mod_categories.whisper.notification_title");
      }
      // Core `custom.js` behavior: no title of its own, none at all. The
      // base class's would look up notifications.titles.custom, which core
      // doesn't have, and show the missing key on hover.
      if (this.notification.data?.title) {
        return i18n(this.notification.data.title);
      }
      return "";
    }

    // The plugin's registered shield icon, so the notification reads
    // unambiguously as a moderator/staff item.
    get icon(): string {
      if (this.isModElection) {
        return "check-to-slot";
      }
      if (this.isReqpm) {
        return this.reqpmKind === "shared" ? "id-card" : "address-card";
      }
      if (this.isDisteleplus) {
        return this.disteleplusKind === "poll_closed"
          ? "chart-simple"
          : "comments";
      }
      if (this.isModNote) {
        return "shield-halved";
      }
      // Core `custom.js` behavior.
      return `notification.${this.notification.data?.message}`;
    }

    // Accurate, self-describing label naming the acting moderator —
    // e.g. "added a moderator note", "deleted a post", "added a note on a user".
    get label(): string {
      if (this.isModElection) {
        return i18n("mod_elections.title");
      }
      if (this.isReqpm) {
        return this.username;
      }
      if (this.isDisteleplus) {
        if (this.disteleplusKind === "poll_closed") {
          return i18n("disteleplus.poll.closed_label");
        }
        return i18n("disteleplus.mention_label", { username: this.username });
      }
      if (this.isModNote) {
        return i18n(`discourse_mod_categories.${this.modNoteKey}`, {
          username: this.username,
        });
      }
      return super.label;
    }

    // Second line: the excerpt (note body / post body / reply body)
    // when available, falling back to the topic title.
    get description(): string {
      if (this.isModElection) {
        return i18n(
          `mod_elections.notifications.${this.notification.data?.mod_election_kind}`
        );
      }
      if (this.isReqpm) {
        return i18n(`reqpm.notifications.${this.reqpmKind}`);
      }
      if (this.isDisteleplus) {
        return this.notification.data?.excerpt;
      }
      if (this.isModNote) {
        return (
          this.notification.data?.excerpt || this.notification.data?.topic_title
        );
      }
      return super.description;
    }
  };
}
