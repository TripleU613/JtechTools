import { tracked } from "@glimmer/tracking";
import type Owner from "@ember/owner";
import type RouterService from "@ember/routing/router-service";
import Service, { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import KeyValueStore from "discourse/lib/key-value-store";
import { emojiUrlFor } from "discourse/lib/text";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type AppEventsService from "discourse/services/app-events";
import type SiteSettingsService from "discourse/services/site-settings";
import type { MessageBus } from "../lib/message-bus.ts";

// Fields the plugin reads off the current user that core's User model does
// not declare.
export type DisteleplusCurrentUser = User & {
  id: number;
  username: string;
  admin: boolean;
  moderator: boolean;
  staff: boolean;
  can_access_disteleplus?: boolean;
  groups?: { name: string }[];
};

// Core's SiteSettingsService declaration carries no settings; these are the
// client settings the Disteleplus UI reads.
export type DisteleplusSiteSettings = SiteSettingsService & {
  disteleplus_enabled: boolean;
  disteleplus_voice_notes_enabled: boolean;
  disteleplus_voice_player_all_audio: boolean;
  disteleplus_quote_in_topic_enabled: boolean;
  disteleplus_voice_note_max_seconds: number;
  enable_mentions: boolean;
  enable_emoji: boolean;
};

// ── server payloads (lib/discourse_disteleplus/message_serializer.rb) ─────

export interface DisteleplusUserSummary {
  id: number;
  username: string;
  name: string | null;
  avatar_template: string;
}

export interface DisteleplusUser extends DisteleplusUserSummary {
  admin: boolean;
  moderator: boolean;
}

export interface ListenedUser extends DisteleplusUserSummary {
  listened_at: string | null;
}

export interface ReactionUser extends DisteleplusUser {
  reacted_at: string;
}

export interface RawUpload {
  id: number;
  url: string;
  short_url: string;
  original_filename: string;
  extension: string;
  filesize: number;
  width: number | null;
  height: number | null;
  thumbnail_width: number | null;
  thumbnail_height: number | null;
}

export type UploadKind = "document" | "image" | "audio" | "video";

export interface DisteleplusUpload extends RawUpload {
  kind: UploadKind;
  voice: boolean;
}

export interface RawReaction {
  emoji: string;
  count: number;
  reacted: boolean;
  // serialize_user returns nil for a deleted reactor.
  users: (ReactionUser | null)[];
}

export interface Reaction extends RawReaction {
  url: string | undefined;
  display: string;
}

export interface ReplyPreview {
  id: number;
  deleted: boolean;
  excerpt: string;
  external_sender_name: string | null;
  user: DisteleplusUser | null;
  upload_count: number;
  thumbnail_url: string | null;
  attachment_name: string | null;
}

export type PollVoter = DisteleplusUserSummary;

export interface PollOption {
  id: string;
  html: string;
  votes: number;
  chosen: boolean;
  voters: PollVoter[];
}

export interface MessagePoll {
  post_id: number;
  topic_id: number;
  name: string;
  type: string;
  status: string;
  closed: boolean;
  close_at: string | null;
  public: boolean;
  voters: number;
  options: PollOption[];
}

export interface RawMessage {
  id: number;
  raw: string;
  cooked: string;
  source: string;
  external_sender_name: string | null;
  deleted: boolean;
  edited_at: string | null;
  created_at: string;
  updated_at: string;
  user: DisteleplusUser | null;
  uploads: RawUpload[];
  reactions: RawReaction[];
  reply_to: ReplyPreview | null;
  can_edit: boolean;
  can_delete: boolean;
  can_react: boolean;
  listened_by: ListenedUser[];
  poll: MessagePoll | null;
}

export interface DisteleplusMessage extends Omit<
  RawMessage,
  "uploads" | "reactions"
> {
  mine: boolean;
  createdDate: Date;
  uploads: DisteleplusUpload[];
  reactions: Reaction[];
}

export interface ReadState {
  // Absent on entries that arrived over the bus.
  user_id?: number;
  username: string;
  name: string | null;
  avatar_template: string;
  last_read_message_id: number;
  updated_at: string | null;
}

export interface Typer {
  user_id: number;
  username: string;
  name: string | null;
  until: number;
}

export interface DrawerSize {
  width: number;
  height: number;
}

export type NewMessageListener = (
  message: DisteleplusMessage,
  info: { mine: boolean }
) => void;

interface ConversationMeta {
  has_more: boolean;
  has_newer?: boolean;
  unread_count?: number;
  unread_mention_count?: number;
  message_bus_last_id?: number;
  latest_message_id?: number | null;
  last_read_message_id?: number | null;
  read_receipts_enabled?: boolean;
  polls_enabled?: boolean;
  polls_topic_id?: number;
}

interface MessagesResponse {
  messages: RawMessage[];
  meta: ConversationMeta;
}

interface MessageResponse {
  message: RawMessage;
}

interface SearchResponse {
  results: RawMessage[];
  count: number;
}

interface ReadStatesResponse {
  read_states?: ReadState[];
}

// Publisher.publish / publish_read_state / publish_listen share a channel.
interface ConversationEvent {
  type?: string;
  actor_id?: number | null;
  message?: RawMessage;
  message_id?: number;
  user_id?: number;
  username?: string;
  name?: string | null;
  avatar_template?: string;
  last_read_message_id?: number;
  updated_at?: string;
}

interface TypingEvent {
  user_id: number;
  username: string;
  name: string | null;
}

// Core discourse-poll's serialized poll, as sent by /polls/* and the
// /polls/<topic id> channel.
interface CorePollOption {
  id: string;
  html: string;
  votes?: number;
}

interface CorePoll {
  status?: string;
  close?: string | null;
  voters?: number;
  options?: CorePollOption[];
  preloaded_voters?: Record<string, PollVoter[]> | null;
}

interface CorePollUpdate {
  post_id?: number;
  polls?: CorePoll[];
}

interface CorePollVoteResponse {
  poll?: CorePoll;
  vote?: string[];
}

export interface PollVotersResponse {
  voters?: Record<string, PollVoter[]>;
}

const BASE = "/jtech-disteleplus";
const CHANNEL = "/disteleplus/conversation";
const TYPING_CHANNEL = "/disteleplus/typing";
const TYPING_TTL = 5000;
const TYPING_THROTTLE = 3000;
const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "webp"]);
const VIDEO_EXTENSIONS = new Set(["mp4", "mov", "webm"]);
const AUDIO_EXTENSIONS = new Set([
  "mp3",
  "m4a",
  "ogg",
  "oga",
  "wav",
  "flac",
  "opus",
  "aac",
]);
const DRAFT_KEY = "disteleplus-draft";
const STORE_NAMESPACE = "disteleplus_";
const PREFERRED_MODE_KEY = "preferred_mode";
const FULL_PAGE = "FULL_PAGE";
const DRAWER = "DRAWER";
const DEFAULT_SIZE = { width: 400, height: 530 };
const MIN_WIDTH = 250;
const MIN_HEIGHT = 300;

export default class DisteleplusService extends Service {
  @service declare currentUser: DisteleplusCurrentUser | null;
  @service declare messageBus: MessageBus;
  @service declare site: Site;
  @service declare router: RouterService;
  @service declare appEvents: AppEventsService;

  @tracked messages: DisteleplusMessage[] = [];
  @tracked loading = false;
  @tracked loadingOlder = false;
  @tracked loaded = false;
  @tracked sending = false;
  @tracked unreadCount = 0;
  // Unread messages that mention the user: the header badge and the tab
  // title count only these, as the bell does
  @tracked unreadMentionCount = 0;
  @tracked hasMore = false;
  @tracked error: unknown = null;
  // Composer draft, restored across navigations (and reloads via localStorage).
  @tracked draft = "";

  // Drawer state, modelled on core Chat's ChatStateManager / ChatDrawerSize.
  @tracked isDrawerActive = false;
  @tracked isDrawerExpanded = false;
  @tracked drawerSize: DrawerSize = DEFAULT_SIZE;
  // draws its unread divider after this id.
  @tracked openedAtReadId: number | null = null;
  // Search UI open (drawer + full page share it) and results.
  @tracked searchOpen = false;
  @tracked searchTerm = "";
  @tracked searchResults: DisteleplusMessage[] | null = null;
  @tracked searching = false;
  // than the live tail.
  @tracked detached = false;
  // [{ user_id, username, name, until }]
  @tracked typers: Typer[] = [];
  // user_id → { username, name, avatar_template, last_read_message_id }.
  // Powers the "Seen by" chip; replaced wholesale so getters recompute.
  @tracked readStates: Record<number, ReadState> = {};
  @tracked readReceiptsEnabled = false;
  @tracked pollsEnabled = false;
  // The holder topic whose core /polls/<id> MessageBus channel carries votes.
  pollsChannelTopicId: number | null = null;
  store = new KeyValueStore(STORE_NAMESPACE);

  // Message id a notification deep link (#m<id>) asked to land on. Set by
  // the route/drawer opener, consumed once by the conversation component.
  pendingJumpId: number | null = null;

  // True while the timeline shows a window around a searched message rather

  lastTypingSentAt = 0;

  latestMessageId: number | null = null;
  lastReadMessageId: number | null = null;
  subscribed = false;
  viewing = false;
  loadPromise: Promise<DisteleplusMessage[]> | null = null;
  // Read cursor as it stood when the conversation was opened; the timeline

  listeners = new Set<NewMessageListener>();

  declare typingSweep: ReturnType<typeof setTimeout> | undefined;

  onRealtime = (payload: ConversationEvent | null) => {
    if (payload?.type === "listened" && payload.message_id) {
      const message = this.messages.find((m) => m.id === payload.message_id);
      if (
        message &&
        !(message.listened_by || []).some((u) => u.id === payload.user_id)
      ) {
        this.upsert({
          ...message,
          listened_by: [
            ...(message.listened_by || []),
            {
              id: payload.user_id,
              username: payload.username,
              name: payload.name,
              avatar_template: payload.avatar_template,
              listened_at: new Date().toISOString(),
            },
          ],
        });
      }
      return;
    }
    if (payload?.type === "read" && payload.user_id) {
      if (payload.user_id !== this.currentUser?.id) {
        this.readStates = {
          ...this.readStates,
          [payload.user_id]: {
            username: payload.username,
            name: payload.name,
            avatar_template: payload.avatar_template,
            last_read_message_id: payload.last_read_message_id,
            updated_at: payload.updated_at,
          },
        };
      }
      return;
    }
    if (!payload?.message) {
      return;
    }
    if (payload.type === "created" && this.detached) {
      this.latestMessageId = Math.max(
        this.latestMessageId || 0,
        payload.message.id
      );
      if (payload.message.user?.id !== this.currentUser.id) {
        this.unreadCount += 1;
        this.countMention(payload.message);
      }
      return;
    }
    if (payload.type === "created") {
      this.clearTyper(payload.message.user?.id);
    }
    const existed = this.messages.some(
      (message) => message.id === payload.message.id
    );
    const message = this.upsert(payload.message);
    this.latestMessageId = Math.max(this.latestMessageId || 0, message.id);
    if (payload.type === "created" && !existed) {
      const mine = message.user?.id === this.currentUser.id;
      if (!mine && !this.viewing) {
        this.unreadCount += 1;
        this.countMention(message);
      }
      // The timeline decides whether to auto-scroll (and mark read) or show
      // the "new messages" pill, so a reader scrolled up is not yanked down.
      this.listeners.forEach((callback) => callback(message, { mine }));
      if (!mine && this.viewing && this.listeners.size === 0) {
        this.markRead(message.id);
      }
    }
  };

  lastAppURL: string | null = null;

  // ── typing ────────────────────────────────────────────────────────────────
  onTyping = (payload: TypingEvent | null) => {
    if (!payload?.user_id || payload.user_id === this.currentUser?.id) {
      return;
    }
    const until = Date.now() + TYPING_TTL;
    const others = this.typers.filter((t) => t.user_id !== payload.user_id);
    this.typers = [...others, { ...payload, until }];
    clearTimeout(this.typingSweep);
    this.typingSweep = setTimeout(() => this.sweepTypers(), TYPING_TTL + 50);
  };

  // First play of a voice note — record the sender's "listened" receipt.
  // One shot per message per session; the server dedupes across sessions.
  listenedSent = new Set<number>();

  onPollUpdate = (payload: CorePollUpdate | null) => {
    const corePoll = (payload?.polls || [])[0];
    if (!corePoll || !payload.post_id) {
      return;
    }
    const message = this.messages.find(
      (candidate) => candidate.poll?.post_id === payload.post_id
    );
    if (message) {
      this.applyCorePoll(message, corePoll);
    }
  };

  constructor(owner?: Owner) {
    super(owner);
    try {
      this.draft = window.localStorage.getItem(DRAFT_KEY) || "";
    } catch {
      this.draft = "";
    }
    this.drawerSize = {
      width: Math.max(
        this.store.getObject("width") || DEFAULT_SIZE.width,
        MIN_WIDTH
      ),
      height: Math.max(
        this.store.getObject("height") || DEFAULT_SIZE.height,
        MIN_HEIGHT
      ),
    };
  }

  // ── drawer / full page ────────────────────────────────────────────────────

  get isFullPageActive(): boolean {
    return this.router.currentRouteName === "disteleplus";
  }

  get isActive(): boolean {
    return this.isFullPageActive || this.isDrawerActive;
  }

  // Mobile is always full page; desktop defaults to the drawer unless the
  // user chose "open in full page".
  get isFullPagePreferred(): boolean {
    return !!(
      this.site.mobileView ||
      this.store.getObject(PREFERRED_MODE_KEY) === FULL_PAGE
    );
  }

  get isDrawerPreferred(): boolean {
    return !this.isFullPagePreferred;
  }

  storeAppURL(): void {
    const url = this.router.currentURL;
    if (url && !url.startsWith("/disteleplus")) {
      this.lastAppURL = url;
    }
  }

  prefersFullPage(): void {
    this.store.setObject({ key: PREFERRED_MODE_KEY, value: FULL_PAGE });
  }

  prefersDrawer(): void {
    this.store.setObject({ key: PREFERRED_MODE_KEY, value: DRAWER });
  }

  openDrawer(): void {
    this.isDrawerActive = true;
    this.isDrawerExpanded = true;
    this.ensureLoaded().catch(() => {});
    this.appEvents.trigger("disteleplus:drawer-changed");
  }

  closeDrawer(): void {
    this.isDrawerActive = false;
    this.isDrawerExpanded = false;
    this.appEvents.trigger("disteleplus:drawer-changed");
  }

  toggleDrawerExpanded(): void {
    this.isDrawerActive = true;
    this.isDrawerExpanded = !this.isDrawerExpanded;
    this.appEvents.trigger("disteleplus:drawer-changed");
  }

  setDrawerSize({ width, height }: DrawerSize): void {
    const next = {
      width: Math.max(Math.round(width), MIN_WIDTH),
      height: Math.max(Math.round(height), MIN_HEIGHT),
    };
    this.drawerSize = next;
    this.store.setObject({ key: "width", value: next.width });
    this.store.setObject({ key: "height", value: next.height });
  }

  setDraft(value: string | null | undefined): void {
    this.draft = value || "";
    try {
      if (this.draft) {
        window.localStorage.setItem(DRAFT_KEY, this.draft);
      } else {
        window.localStorage.removeItem(DRAFT_KEY);
      }
    } catch {
      // Storage may be unavailable; the in-memory draft still works.
    }
  }

  onNewMessage(callback: NewMessageListener): () => boolean {
    this.listeners.add(callback);
    return () => this.listeners.delete(callback);
  }

  // Ask whichever conversation is (or becomes) visible to jump to a message.
  // A mounted conversation reacts to the app event immediately; one mounted
  // later picks the id up from pendingJumpId in its open sequence.
  requestJump(messageId: number | string): void {
    const id = parseInt(String(messageId), 10);
    if (!id) {
      return;
    }
    this.pendingJumpId = id;
    this.appEvents.trigger("disteleplus:jump-to-message", id);
  }

  consumePendingJump(): number | null {
    const id = this.pendingJumpId;
    this.pendingJumpId = null;
    return id;
  }

  ensureLoaded(): Promise<DisteleplusMessage[]> {
    if (this.loaded) {
      return Promise.resolve(this.messages);
    }
    if (this.loadPromise) {
      return this.loadPromise;
    }

    this.loading = true;
    this.error = null;
    this.loadPromise = ajax(`${BASE}/conversation`)
      .then((response: MessagesResponse) => {
        this.messages = response.messages.map((message) =>
          this.hydrate(message)
        );
        this.unreadCount = response.meta.unread_count || 0;
        this.unreadMentionCount = response.meta.unread_mention_count || 0;
        this.hasMore = response.meta.has_more;
        this.latestMessageId = response.meta.latest_message_id;
        this.lastReadMessageId = response.meta.last_read_message_id;
        this.openedAtReadId = this.lastReadMessageId;
        this.readReceiptsEnabled = !!response.meta.read_receipts_enabled;
        this.pollsEnabled = !!response.meta.polls_enabled;
        this.loaded = true;
        this.subscribe(response.meta.message_bus_last_id);
        if (response.meta.polls_topic_id) {
          this.ensurePollChannel(response.meta.polls_topic_id);
        }
        if (this.readReceiptsEnabled) {
          this.loadReadStates();
        }
        return this.messages;
      })
      .catch((error: unknown) => {
        this.error = error;
        throw error;
      })
      .finally(() => {
        this.loading = false;
        this.loadPromise = null;
      });
    return this.loadPromise;
  }

  async loadOlder(): Promise<DisteleplusMessage[]> {
    if (this.loadingOlder || !this.hasMore || !this.messages.length) {
      return [];
    }
    this.loadingOlder = true;
    try {
      const beforeId = this.messages[0].id;
      const response: MessagesResponse = await ajax(
        `${BASE}/messages?before_id=${beforeId}&limit=40`
      );
      const older = response.messages.map((message) => this.hydrate(message));
      this.messages = [...older, ...this.messages];
      this.hasMore = response.meta.has_more;
      return older;
    } finally {
      this.loadingOlder = false;
    }
  }

  async createMessage({
    raw,
    uploadIds,
    replyToId,
  }: {
    raw: string;
    uploadIds?: number[];
    replyToId?: number;
  }): Promise<RawMessage> {
    this.sending = true;
    try {
      const response: MessageResponse = await ajax(`${BASE}/messages`, {
        type: "POST",
        data: {
          raw,
          upload_ids: uploadIds,
          reply_to_id: replyToId,
        },
      });
      this.upsert(response.message);
      this.setDraft("");
      return response.message;
    } finally {
      this.sending = false;
    }
  }

  async updateMessage(id: number, raw: string): Promise<RawMessage> {
    const response: MessageResponse = await ajax(`${BASE}/messages/${id}`, {
      type: "PUT",
      data: { raw },
    });
    this.upsert(response.message);
    this.setDraft("");
    return response.message;
  }

  async deleteMessage(id: number): Promise<void> {
    const response: MessageResponse = await ajax(`${BASE}/messages/${id}`, {
      type: "DELETE",
    });
    this.upsert(response.message);
  }

  async toggleReaction(
    message: DisteleplusMessage,
    emoji: string
  ): Promise<void> {
    const current = message.reactions.find(
      (reaction) => reaction.emoji === emoji
    );
    const type = current?.reacted ? "DELETE" : "PUT";
    const response: MessageResponse = await ajax(
      `${BASE}/messages/${message.id}/reactions/${encodeURIComponent(emoji)}`,
      { type }
    );
    this.upsert(response.message);
  }

  // As the server's Notifier.mentioned_user_ids: an @mention of the user, or
  // of a group they're in, by the link's target or else its text
  countMention(message: { cooked?: string | null }): void {
    const user = this.currentUser;
    if (!user || !message.cooked) {
      return;
    }
    const doc = new DOMParser().parseFromString(message.cooked, "text/html");
    const target = (el: Element, path: RegExp) =>
      (
        el.getAttribute("href")?.match(path)?.[1] ||
        el.textContent?.replace(/^@/, "") ||
        ""
      ).toLowerCase();
    const groups = new Set(
      (user.groups || []).map((group) => group.name.toLowerCase())
    );
    const mentioned =
      [...doc.querySelectorAll("a.mention, span.mention")].some(
        (el) => target(el, /\/u\/([^/?#]+)/) === user.username.toLowerCase()
      ) ||
      [...doc.querySelectorAll("a.mention-group, span.mention-group")].some(
        (el) => groups.has(target(el, /\/groups\/([^/?#]+)/))
      );
    if (mentioned) {
      this.unreadMentionCount += 1;
    }
  }

  async markRead(id: number | null = this.latestMessageId): Promise<void> {
    if (!id || id <= (this.lastReadMessageId || 0)) {
      return;
    }
    this.lastReadMessageId = id;
    this.unreadCount = 0;
    this.unreadMentionCount = 0;
    await ajax(`${BASE}/read`, {
      type: "POST",
      data: { message_id: id },
    });
  }

  setViewing(value: boolean): void {
    this.viewing = value;
    if (value) {
      this.openedAtReadId = this.lastReadMessageId;
      this.markRead();
    }
  }

  // From the conversation's own point in the channel: subscribing "from now"
  // missed a message sent before the next poll reached the server.
  subscribe(lastId?: number): void {
    if (this.subscribed) {
      return;
    }
    this.messageBus.subscribe(CHANNEL, this.onRealtime, lastId);
    this.messageBus.subscribe(TYPING_CHANNEL, this.onTyping);
    this.subscribed = true;
  }

  sweepTypers(): void {
    const now = Date.now();
    this.typers = this.typers.filter((t) => t.until > now);
    if (this.typers.length) {
      this.typingSweep = setTimeout(() => this.sweepTypers(), 1000);
    }
  }

  clearTyper(userId: number | undefined): void {
    this.typers = this.typers.filter((t) => t.user_id !== userId);
  }

  sendTyping(): void {
    const now = Date.now();
    if (now - this.lastTypingSentAt < TYPING_THROTTLE) {
      return;
    }
    this.lastTypingSentAt = now;
    ajax(`${BASE}/typing`, { type: "POST" }).catch(() => {});
  }

  // ── read receipts ─────────────────────────────────────────────────────────

  async loadReadStates(): Promise<void> {
    try {
      const response: ReadStatesResponse = await ajax(`${BASE}/read-states`);
      const map: Record<number, ReadState> = {};
      (response.read_states || []).forEach((state) => {
        map[state.user_id] = state;
      });
      this.readStates = map;
    } catch {
      // Receipts are decoration — the conversation works without them.
    }
  }

  // Everyone (other than self) whose read cursor has passed `messageId`.
  seenBy(messageId: number): ReadState[] {
    return Object.values(this.readStates).filter(
      (state) => state.last_read_message_id >= messageId
    );
  }

  markListened(messageId: number): void {
    if (!this.readReceiptsEnabled || this.listenedSent.has(messageId)) {
      return;
    }
    this.listenedSent.add(messageId);
    ajax(`${BASE}/messages/${messageId}/listened`, { type: "POST" }).catch(() =>
      this.listenedSent.delete(messageId)
    );
  }

  // ── search / jump ─────────────────────────────────────────────────────────

  toggleSearch(open: boolean = !this.searchOpen): void {
    this.searchOpen = open;
    if (!open) {
      this.searchTerm = "";
      this.searchResults = null;
    }
  }

  async search(term: string): Promise<void> {
    this.searchTerm = term;
    if (term.trim().length < 2) {
      this.searchResults = null;
      return;
    }
    this.searching = true;
    try {
      const response: SearchResponse = await ajax(`${BASE}/search`, {
        data: { q: term },
      });
      if (this.searchTerm === term) {
        this.searchResults = response.results.map((m) => this.hydrate(m));
      }
    } finally {
      this.searching = false;
    }
  }

  // Replace the timeline with a window around `id` (search result jump).
  async loadAround(id: number): Promise<DisteleplusMessage[]> {
    const response: MessagesResponse = await ajax(`${BASE}/messages`, {
      data: { around_id: id, limit: 40 },
    });
    this.messages = response.messages.map((m) => this.hydrate(m));
    this.hasMore = response.meta.has_more;
    this.detached = !!response.meta.has_newer;
    return this.messages;
  }

  // Back to the live tail after a detached jump.
  async reloadLatest(): Promise<void> {
    this.loaded = false;
    this.detached = false;
    await this.ensureLoaded();
  }

  upsert(rawMessage: RawMessage): DisteleplusMessage {
    const message = this.hydrate(rawMessage);
    const index = this.messages.findIndex(
      (candidate) => candidate.id === message.id
    );
    if (index === -1) {
      this.messages = [...this.messages, message].sort((a, b) => a.id - b.id);
    } else {
      const next = [...this.messages];
      next[index] = message;
      this.messages = next;
    }
    // The holder topic is created lazily with the FIRST poll — a message
    // arriving with a poll may carry a channel we aren't listening to yet.
    if (message.poll?.topic_id) {
      this.ensurePollChannel(message.poll.topic_id);
    }
    return message;
  }

  // ── polls ─────────────────────────────────────────────────────────────────
  // Votes are core discourse-poll votes on the backing post; results stream
  // over core's /polls/<holder topic id> channel.

  ensurePollChannel(topicId: number | null | undefined): void {
    if (!topicId || this.pollsChannelTopicId === topicId) {
      return;
    }
    if (this.pollsChannelTopicId) {
      this.messageBus.unsubscribe(
        `/polls/${this.pollsChannelTopicId}`,
        this.onPollUpdate
      );
    }
    this.pollsChannelTopicId = topicId;
    this.messageBus.subscribe(`/polls/${topicId}`, this.onPollUpdate);
  }

  // Merge core's serialized poll into our message-local shape. `chosenSet`
  // comes from a vote response; bus updates carry no per-user votes, so the
  // previous chosen flags are preserved there.
  applyCorePoll(
    message: DisteleplusMessage,
    corePoll: CorePoll,
    chosenSet: Set<string> | null = null
  ): void {
    const previous: Partial<MessagePoll> = message.poll || {};
    const chosen =
      chosenSet ||
      new Set(
        (previous.options || [])
          .filter((option) => option.chosen)
          .map((option) => option.id)
      );
    const previousById: Record<string, PollOption> = {};
    (previous.options || []).forEach((option) => {
      previousById[option.id] = option;
    });
    // Public polls carry per-option voters (core's preloaded_voters, keyed
    // by option digest); keep the last known list when a payload lacks it.
    const preloadedVoters = corePoll.preloaded_voters || null;
    const sourceOptions: CorePollOption[] =
      corePoll.options || previous.options || [];
    const poll = {
      ...previous,
      status: corePoll.status || previous.status,
      closed: (corePoll.status || previous.status) !== "open",
      close_at: corePoll.close || previous.close_at,
      voters: corePoll.voters ?? previous.voters,
      options: sourceOptions.map((option) => ({
        id: option.id,
        html: option.html,
        votes: option.votes ?? 0,
        chosen: chosen.has(option.id),
        voters:
          (preloadedVoters
            ? preloadedVoters[option.id]
            : previousById[option.id]?.voters) || [],
      })),
    } as MessagePoll;
    const next = { ...message, poll };
    this.messages = this.messages.map((candidate) =>
      candidate.id === next.id ? next : candidate
    );
  }

  async votePoll(
    message: DisteleplusMessage,
    optionIds: string[]
  ): Promise<void> {
    const response: CorePollVoteResponse = await ajax("/polls/vote", {
      type: "PUT",
      data: {
        post_id: message.poll.post_id,
        poll_name: message.poll.name,
        options: optionIds,
      },
    });
    this.applyCorePoll(
      message,
      response.poll || {},
      new Set(response.vote || optionIds)
    );
  }

  async retractPollVote(message: DisteleplusMessage): Promise<void> {
    const response: CorePollVoteResponse = await ajax("/polls/vote", {
      type: "DELETE",
      data: { post_id: message.poll.post_id, poll_name: message.poll.name },
    });
    this.applyCorePoll(message, response.poll || {}, new Set<string>());
  }

  // Close or reopen — core checks that the actor owns the backing post or
  // is staff.
  async togglePollStatus(
    message: DisteleplusMessage,
    status: "open" | "closed"
  ): Promise<void> {
    const response: CorePollVoteResponse = await ajax("/polls/toggle_status", {
      type: "PUT",
      data: {
        post_id: message.poll.post_id,
        poll_name: message.poll.name,
        status,
      },
    });
    this.applyCorePoll(message, response.poll || {});
  }

  // Full voter lists for the stats modal (the widget itself only carries
  // the first page core preloads).
  fetchPollVoters(
    message: DisteleplusMessage,
    page = 1
  ): Promise<PollVotersResponse> {
    return ajax("/polls/voters", {
      data: {
        post_id: message.poll.post_id,
        poll_name: message.poll.name,
        limit: 50,
        page,
      },
    });
  }

  hydrate(message: RawMessage): DisteleplusMessage {
    const mine = message.user?.id === this.currentUser?.id;
    const staff = this.currentUser?.admin || this.currentUser?.moderator;
    return {
      ...message,
      mine,
      can_edit:
        message.can_edit ||
        (!message.deleted && message.source === "discourse" && (mine || staff)),
      // a Telegram message too: deleted here, the bot deletes it there
      can_delete: message.can_delete || (!message.deleted && (mine || staff)),
      can_react: !message.deleted,
      createdDate: new Date(message.created_at),
      uploads: (message.uploads || []).map((upload) =>
        this.hydrateUpload(upload)
      ),
      reactions: (message.reactions || []).map((reaction) => ({
        ...reaction,
        url: emojiUrlFor(reaction.emoji),
        display: `:${reaction.emoji}:`,
      })),
    };
  }

  hydrateUpload(upload: RawUpload): DisteleplusUpload {
    const extension = (upload.extension || "").toLowerCase();
    const name = (upload.original_filename || "").toLowerCase();
    // Browser recorders produce voice-note-*.webm / .m4a; webm without pixel
    // dimensions is audio, not video.
    const voiceNote = name.startsWith("voice-note") || name === "voice.ogg";
    const dimensionless = !upload.width && !upload.height;
    let kind: UploadKind = "document";
    if (IMAGE_EXTENSIONS.has(extension)) {
      kind = "image";
    } else if (
      voiceNote ||
      AUDIO_EXTENSIONS.has(extension) ||
      (extension === "webm" && dimensionless)
    ) {
      kind = "audio";
    } else if (VIDEO_EXTENSIONS.has(extension)) {
      kind = "video";
    }
    // The served URL is a sha name — voice-ness must ride along explicitly.
    return { ...upload, kind, voice: voiceNote };
  }
}
