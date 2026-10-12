import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { type default as Owner, getOwner } from "@ember/owner";
import type RouterService from "@ember/routing/router-service";
import { cancel, type Timer } from "@ember/runloop";
import { service } from "@ember/service";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { getURLWithCDN } from "discourse/lib/get-url";
import discourseLater from "discourse/lib/later";
import DiscourseURL from "discourse/lib/url";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type SiteSettingsService from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import type { MessageBus } from "../lib/message-bus";

// Desktop-only, Jelly-style pop-up "toast". Purely ADDITIVE — it renders a
// card when a new notification is published on the current user's
// `/notification/:id` MessageBus channel (the same channel that already
// drives the bell counter and the notifications dropdown) and does nothing
// else. Core notifications, the bell, the dropdown, and read-state are all
// untouched; turning the feature off simply stops the cards from appearing.
//
// Multiple notifications STACK one below another: the newest card sits at the
// top-right (just below the header search) and older ones are pushed down,
// each with its own auto-dismiss timer, up to popup_notifications_max_stack
// at once. A further
// notification drops the oldest (bottom) card so the newest can take its
// place. Clicking a card opens it (routes like the dropdown row); clicking
// anywhere else dismisses them all.
//
// Card layout: the acting user's avatar on the left (with a small type-icon
// badge on its corner), then a heading line "Name — Action" (e.g.
// "pat — Liked your post"), the topic title in bold, and a short preview of
// the message.
//
// Fires for every notification the user receives, including the plugin's
// own `custom` notifications — moderator whispers, flag notes, and
// queued/pending-post approvals/rejections — decoded via their `data`
// markers below. Never mounts on mobile or for users who have not opted in.
const AVATAR_SIZE = 48;
const EXCERPT_LENGTH = 120;
const STALE_MS = 10000;
// Stack depth comes from the popup_notifications_max_stack site setting;
// 3 matches the historical hard-coded value.
const DEFAULT_MAX_TOASTS = 3; // stack up to 3; a 4th drops the oldest (bottom) card
const CUSTOM_TYPE = 14; // Notification.types[:custom]

interface ToastMeta {
  icon: string;
  action: string;
}

interface PopupToast {
  key: number | string;
  name: string;
  action: string;
  icon: string;
  title: string;
  excerpt: string;
  avatarUrl: string | null;
  url: string;
  timer: Timer | null;
}

// The `data` of a core or plugin notification, as far as the card reads it.
interface PopupNotificationData {
  display_username?: string;
  username?: string;
  original_username?: string;
  mentioned_by_username?: string;
  topic_title?: string;
  excerpt?: string;
  avatar_template?: string;
  url?: string;
  original_post_id?: number;
  disteleplus?: boolean;
  disteleplus_kind?: string;
  disteleplus_message_id?: number;
  mod_whisper?: boolean;
  reqpm?: boolean;
  mod_note?: boolean;
  mod_note_kind?: string;
}

interface PopupNotification {
  id: number;
  notification_type: number;
  read: boolean;
  created_at: string;
  data?: PopupNotificationData;
  fancy_title?: string;
  topic_id?: number;
  post_number?: number;
  slug?: string;
}

// `/notification/:user_id` payload.
interface NotificationChannelMessage {
  last_notification?: { notification?: PopupNotification };
}

// A serialized message on the disteleplus conversation channel.
interface ConversationMessage {
  id: number;
  created_at: string;
  raw?: string;
  external_sender_name?: string;
  user?: {
    id: number;
    name?: string;
    username?: string;
    avatar_template?: string;
  };
}

interface ConversationEvent {
  type?: string;
  message?: ConversationMessage;
}

interface PopupPost {
  avatar_template?: string;
  cooked?: string;
}

interface DisteleplusDrawerState {
  isDrawerActive?: boolean;
  isDrawerExpanded?: boolean;
}

type PopupSiteSettings = SiteSettingsService & {
  popup_notifications_enabled: boolean;
  popup_notifications_excluded_types: string;
  popup_notifications_timeout_seconds: number | string;
  popup_notifications_max_stack: number | string;
  disteleplus_enabled: boolean;
};

// Mounted into the above-footer outlet; reads no arguments.
interface JtechPopupNotificationSignature {
  Args: { outletArgs?: Record<string, unknown> };
}

type PopupCurrentUser = User & {
  id: number;
  username: string;
  jtech_popup_notifications_enabled?: boolean;
  isInDoNotDisturb(): boolean;
};

// notification_type (core enum, stable) → icon + action i18n key suffix.
const CORE_TYPES: Record<number, ToastMeta> = {
  1: { icon: "at", action: "mentioned" },
  2: { icon: "reply", action: "replied" },
  3: { icon: "quote-right", action: "quoted" },
  4: { icon: "pencil", action: "edited" },
  5: { icon: "heart", action: "liked" },
  6: { icon: "envelope", action: "messaged" },
  7: { icon: "envelope", action: "messaged" },
  9: { icon: "reply", action: "posted" },
  11: { icon: "link", action: "linked" },
  12: { icon: "certificate", action: "badge" },
  15: { icon: "at", action: "mentioned" },
  17: { icon: "reply", action: "posted" },
  19: { icon: "heart", action: "liked" },
  20: { icon: "check", action: "post_approved" },
  25: { icon: "heart", action: "liked" },
};

// This plugin's `custom` notifications, keyed by their `data.mod_note_kind`.
const MOD_NOTE_KINDS: Record<string, ToastMeta> = {
  post_deleted: { icon: "trash-can", action: "post_deleted" },
  post_approved: { icon: "check", action: "post_approved" },
  post_rejected: { icon: "xmark", action: "post_rejected" },
  user_note: { icon: "shield-halved", action: "user_note" },
  flag_note: { icon: "flag", action: "flag_note" },
  note: { icon: "shield-halved", action: "note" },
};

// "generic" is also the choice-list value exposed by the
// popup_notifications_excluded_types site setting. (Not "other" — that key
// would make the i18n linter treat the action map as a pluralized string.)
const FALLBACK: ToastMeta = { icon: "bell", action: "generic" };

// Actions whose post is the recipient's own (someone liked or edited it).
const ABOUT_YOUR_POST = new Set(["liked", "edited"]);

// Disteleplus native conversation: its MessageBus channel is user-scoped by
// the server-side Publisher, so subscribing here only ever yields messages
// this user may see.
const DISTELEPLUS_CHANNEL = "/disteleplus/conversation";

export default class JtechPopupNotification extends Component<JtechPopupNotificationSignature> {
  @service declare currentUser: PopupCurrentUser | null;
  @service declare siteSettings: PopupSiteSettings;
  @service declare site: Site;
  @service declare messageBus: MessageBus;
  @service declare router: RouterService;

  @tracked toasts: PopupToast[] = [];

  declare mountedAt: number;
  channel: string | null = null;
  disteleplusSubscribed = false;
  seen = new Set<number | string>();
  listening = false;
  paused = false;

  constructor(owner: Owner, args: JtechPopupNotificationSignature["Args"]) {
    super(owner, args);
    if (!this.currentUser || !this.siteSettings.popup_notifications_enabled) {
      return;
    }
    this.mountedAt = Date.now();
    this.channel = `/notification/${this.currentUser.id}`;
    this.onDocumentClick = this.onDocumentClick.bind(this);
    this.messageBus.subscribe(this.channel, this.onMessage);
    if (this.siteSettings.disteleplus_enabled) {
      this.messageBus.subscribe(DISTELEPLUS_CHANNEL, this.onConversationEvent);
      this.disteleplusSubscribed = true;
    }
  }

  willDestroy() {
    super.willDestroy();
    this.dismissAll();
    if (this.channel) {
      this.messageBus.unsubscribe(this.channel, this.onMessage);
    }
    if (this.disteleplusSubscribed) {
      this.messageBus.unsubscribe(
        DISTELEPLUS_CHANNEL,
        this.onConversationEvent
      );
    }
  }

  // Read live so saving the account-page dropdown (which mirrors the value
  // onto currentUser) takes effect without a page reload.
  get prefEnabled(): boolean {
    return !!this.currentUser?.jtech_popup_notifications_enabled;
  }

  // Everything that silences a card, checked when each one arrives: the
  // site switch (so an admin turning it off stops already-open tabs), the
  // user's preference, Do Not Disturb, and a phone-sized window (read live,
  // since the view follows the window size).
  get muted(): boolean {
    return (
      !this.siteSettings.popup_notifications_enabled ||
      !this.prefEnabled ||
      this.site.mobileView ||
      !!this.currentUser?.isInDoNotDisturb?.()
    );
  }

  // True while the user is already looking at the conversation — full page
  // route, or the drawer open and expanded (service looked up lazily so this
  // component keeps working if the disteleplus module is disabled).
  get conversationVisible(): boolean {
    if (this.router.currentRouteName === "disteleplus") {
      return true;
    }
    try {
      const disteleplus = getOwner(this).lookup("service:disteleplus") as
        | DisteleplusDrawerState
        | undefined;
      return !!(disteleplus?.isDrawerActive && disteleplus?.isDrawerExpanded);
    } catch {
      return false;
    }
  }

  // Icon + action label for a notification. Core types come from the stable
  // enum map; our own `custom` notifications are decoded from their data
  // markers (whisper, REQ-PM, mod-note kinds — which cover flag notes and
  // queued/pending-post approvals and rejections).
  metaFor(notification: PopupNotification): ToastMeta {
    const data = notification.data || {};
    if (notification.notification_type === CUSTOM_TYPE) {
      if (data.disteleplus) {
        if (data.disteleplus_kind === "poll_closed") {
          return { icon: "chart-simple", action: "poll_closed" };
        }
        return { icon: "comments", action: "chat_mentioned" };
      }
      if (data.mod_whisper) {
        return { icon: "eye", action: "whispered" };
      }
      if (data.reqpm) {
        return { icon: "address-card", action: "reqpm" };
      }
      if (data.mod_note) {
        return MOD_NOTE_KINDS[data.mod_note_kind] || MOD_NOTE_KINDS.note;
      }
      return FALLBACK;
    }
    return CORE_TYPES[notification.notification_type] || FALLBACK;
  }

  // Every native-conversation message pops a card (not only @mentions).
  // The payload is the serialized message straight off the conversation
  // channel — no enrichment fetch needed.
  @action
  onConversationEvent(data: unknown) {
    const payload = data as ConversationEvent | null | undefined;
    try {
      if (this.muted) {
        return;
      }
      if (payload?.type !== "created" || !payload.message?.id) {
        return;
      }
      const message = payload.message;
      if (message.user?.id === this.currentUser.id) {
        return;
      }
      const excluded = (
        this.siteSettings.popup_notifications_excluded_types || ""
      ).split("|");
      if (excluded.includes("chat_message")) {
        return;
      }
      // One card per conversation message: the @mention notification path
      // claims the same key, so whichever arrives first wins.
      const key = `dp-${message.id}`;
      if (this.seen.has(key)) {
        return;
      }
      const createdAt = Date.parse(message.created_at);
      if (createdAt && createdAt < this.mountedAt - STALE_MS) {
        return;
      }
      if (this.conversationVisible) {
        return;
      }
      this.seen.add(key);

      const name =
        message.user?.name ||
        message.user?.username ||
        message.external_sender_name ||
        i18n("jtech_popup_notifications.someone");
      let avatarUrl = null;
      if (message.user?.avatar_template) {
        avatarUrl = getURLWithCDN(
          message.user.avatar_template.replace("{size}", String(AVATAR_SIZE))
        );
      }
      let excerpt = (message.raw || "").replace(/\s+/g, " ").trim();
      if (excerpt.length > EXCERPT_LENGTH) {
        excerpt = `${excerpt.slice(0, EXCERPT_LENGTH)}…`;
      }
      this.addToast({
        key,
        name,
        action: i18n("jtech_popup_notifications.action.chat_message"),
        icon: "comments",
        title: "",
        excerpt,
        avatarUrl,
        url: `/disteleplus#m${message.id}`,
        timer: null,
      });
    } catch {
      // A malformed payload must never break the page.
    }
  }

  @action
  async onMessage(data: unknown) {
    const payload = data as NotificationChannelMessage | null | undefined;
    try {
      if (this.muted) {
        return;
      }
      const notification = payload?.last_notification?.notification;
      if (!notification || notification.read) {
        return;
      }
      // Client-side list settings arrive as a "|"-joined string.
      const excluded = (
        this.siteSettings.popup_notifications_excluded_types || ""
      ).split("|");
      if (excluded.includes(this.metaFor(notification).action)) {
        return;
      }
      // Show each notification at most once (guards MessageBus replays and
      // re-adds after dismissal).
      if (this.seen.has(notification.id)) {
        return;
      }
      // Ignore MessageBus backlog replayed from before this tab mounted.
      const createdAt = Date.parse(notification.created_at);
      if (createdAt && createdAt < this.mountedAt - STALE_MS) {
        return;
      }
      // A conversation @mention also travels the chat_message path — claim
      // the shared per-message key so only one card shows for it.
      if (notification.data?.disteleplus_message_id) {
        const dpKey = `dp-${notification.data.disteleplus_message_id}`;
        if (this.seen.has(dpKey)) {
          return;
        }
        this.seen.add(dpKey);
      }
      this.seen.add(notification.id);
      await this.present(notification);
    } catch {
      // A malformed payload must never break the page.
    }
  }

  async present(notification: PopupNotification): Promise<void> {
    const data = notification.data || {};
    const meta = this.metaFor(notification);
    const toast: PopupToast = {
      key: notification.id,
      name:
        data.display_username ||
        data.username ||
        data.original_username ||
        data.mentioned_by_username ||
        i18n("jtech_popup_notifications.someone"),
      action: i18n(`jtech_popup_notifications.action.${meta.action}`),
      icon: meta.icon,
      title: notification.fancy_title || data.topic_title || "",
      excerpt: data.excerpt || "",
      avatarUrl: null,
      url: this.urlFor(notification),
      timer: null,
    };

    // Notifications that carry the acting user's avatar directly (the
    // conversation notifier does) skip the post fetch — there is no post.
    if (data.avatar_template) {
      toast.avatarUrl = getURLWithCDN(
        data.avatar_template.replace("{size}", String(AVATAR_SIZE))
      );
      this.addToast(toast);
      return;
    }

    // Enrich with the acting user's avatar + a preview of their message from
    // the source post. Best-effort: the card still shows without it (custom
    // notifications such as flag notes have no source post — they render the
    // type icon on its own instead of an avatar).
    try {
      const post = await this.fetchPost(notification, data);
      if (post) {
        // For likes and edits the post is the recipient's own, so its
        // avatar would be theirs, not the actor's; show the type icon.
        if (post.avatar_template && !ABOUT_YOUR_POST.has(meta.action)) {
          toast.avatarUrl = getURLWithCDN(
            post.avatar_template.replace("{size}", String(AVATAR_SIZE))
          );
        }
        if (!toast.excerpt && post.cooked) {
          toast.excerpt = this.excerptFrom(post.cooked);
        }
      }
    } catch {
      // ignore enrichment failure — show what we have
    }

    // Anything may have changed during the await.
    if (this.muted) {
      return;
    }
    this.addToast(toast);
  }

  // Prepend the newest card; drop the oldest beyond the cap. Each card gets
  // its own auto-dismiss timer.
  addToast(toast: PopupToast): void {
    if (!this.paused) {
      this.startTimer(toast);
    }

    // A dropped card stays in `seen`: a later state update carrying the same
    // notification must not bring it back.
    const next = [toast, ...this.toasts];
    const maxToasts =
      parseInt(String(this.siteSettings.popup_notifications_max_stack), 10) ||
      DEFAULT_MAX_TOASTS;
    while (next.length > maxToasts) {
      cancel(next.pop().timer);
    }
    this.toasts = next;

    if (!this.listening) {
      document.addEventListener("click", this.onDocumentClick, true);
      this.listening = true;
    }
  }

  startTimer(toast: PopupToast): void {
    const secs =
      parseInt(
        String(this.siteSettings.popup_notifications_timeout_seconds),
        10
      ) || 20;
    cancel(toast.timer);
    toast.timer = discourseLater(this, this.dismiss, toast, secs * 1000);
  }

  // Cards stay while the pointer or keyboard focus is on them, so they can
  // be read, and each gets its full time again afterwards.
  @action
  pause() {
    this.paused = true;
    this.toasts.forEach((t) => cancel(t.timer));
  }

  @action
  resume() {
    this.paused = false;
    this.toasts.forEach((t) => this.startTimer(t));
  }

  fetchPost(
    notification: PopupNotification,
    data: PopupNotificationData
  ): Promise<PopupPost> | null {
    if (data.original_post_id) {
      return ajax(`/posts/${data.original_post_id}.json`);
    }
    if (notification.topic_id && notification.post_number) {
      return ajax(
        `/posts/by_number/${notification.topic_id}/${notification.post_number}.json`
      );
    }
    return null;
  }

  // DOMParser builds an inert document: unlike innerHTML on a detached
  // element, it doesn't start loading the post's images.
  excerptFrom(cooked: string): string {
    const doc = new DOMParser().parseFromString(cooked, "text/html");
    const text = (doc.body.textContent || "").replace(/\s+/g, " ").trim();
    return text.length > EXCERPT_LENGTH
      ? `${text.slice(0, EXCERPT_LENGTH)}…`
      : text;
  }

  urlFor(notification: PopupNotification): string {
    const data = notification.data || {};
    if (notification.topic_id && notification.slug) {
      const suffix = notification.post_number
        ? `/${notification.post_number}`
        : "";
      return `/t/${notification.slug}/${notification.topic_id}${suffix}`;
    }
    if (data.url) {
      return data.url;
    }
    return `/u/${this.currentUser.username}/notifications`;
  }

  stopListening(): void {
    if (this.listening) {
      document.removeEventListener("click", this.onDocumentClick, true);
      this.listening = false;
    }
  }

  onDocumentClick(event: MouseEvent): void {
    // A click anywhere outside every card dismisses them all. Clicks on a
    // card are handled by `open` (this capture-phase listener only acts when
    // the target is outside).
    if (!(event.target as Element).closest(".jtech-popup-toast")) {
      this.dismissAll();
    }
  }

  @action
  open(toast: PopupToast) {
    const url = toast.url;
    this.dismiss(toast);
    if (url) {
      DiscourseURL.routeTo(url, undefined);
    }
  }

  @action
  dismiss(toast: PopupToast) {
    cancel(toast.timer);
    this.toasts = this.toasts.filter((t) => t !== toast);
    if (this.toasts.length === 0) {
      this.paused = false;
      this.stopListening();
    }
  }

  dismissAll(): void {
    this.toasts.forEach((t) => cancel(t.timer));
    this.toasts = [];
    this.paused = false;
    this.stopListening();
  }

  <template>
    <div
      aria-live="polite"
      class="jtech-popup-toasts"
      role="status"
      {{on "mouseenter" this.pause}}
      {{on "mouseleave" this.resume}}
      {{on "focusin" this.pause}}
      {{on "focusout" this.resume}}
    >
      {{#each this.toasts key="key" as |toast|}}
        <div class="jtech-popup-toast">
          <button
            class="jtech-popup-toast__open"
            type="button"
            {{on "click" (fn this.open toast)}}
          >
            <span class="jtech-popup-toast__avatar">
              {{#if toast.avatarUrl}}
                <img alt="" height="44" src={{toast.avatarUrl}} width="44" />
                <span class="jtech-popup-toast__type-badge">
                  {{icon toast.icon}}
                </span>
              {{else}}
                <span class="jtech-popup-toast__type-icon">
                  {{icon toast.icon}}
                </span>
              {{/if}}
            </span>
            <span class="jtech-popup-toast__body">
              <span class="jtech-popup-toast__heading">
                <span class="jtech-popup-toast__name">{{toast.name}}</span>
                <span class="jtech-popup-toast__action">—
                  {{toast.action}}</span>
              </span>
              {{#if toast.title}}
                <span class="jtech-popup-toast__title">{{toast.title}}</span>
              {{/if}}
              {{#if toast.excerpt}}
                <span
                  class="jtech-popup-toast__excerpt"
                >{{toast.excerpt}}</span>
              {{/if}}
            </span>
          </button>
          <button
            aria-label={{i18n "jtech_popup_notifications.close"}}
            class="jtech-popup-toast__close btn-flat"
            type="button"
            {{on "click" (fn this.dismiss toast)}}
          >
            {{icon "xmark"}}
          </button>
        </div>
      {{/each}}
    </div>
  </template>
}
