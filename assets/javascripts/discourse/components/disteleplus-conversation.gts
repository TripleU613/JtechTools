import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import { htmlSafe, type SafeString } from "@ember/template";
import { modifier } from "ember-modifier";
import { emojiSearch } from "pretty-text/emoji";
import { eq, or } from "truth-helpers";
import DButton from "discourse/components/d-button";
import EmojiAutocompleteResults from "discourse/components/emoji-autocomplete-results";
import EmojiPickerDetached from "discourse/components/emoji-picker/detached";
import UserAutocompleteResults from "discourse/components/user-autocomplete-results";
import type DialogService from "discourse/dialog-holder/services/dialog";
import type MenuService from "discourse/float-kit/services/menu";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { getAbsoluteURL } from "discourse/lib/get-url";
import lightbox from "discourse/lib/lightbox";
import { emojiUrlFor } from "discourse/lib/text";
import { TextareaAutocompleteHandler } from "discourse/lib/textarea-text-manipulation";
import userSearch, { validateSearchResult } from "discourse/lib/user-search";
import { clipboardCopy } from "discourse/lib/utilities";
import type Site from "discourse/models/site";
import type AppEventsService from "discourse/services/app-events";
import type ComposerService from "discourse/services/composer";
import type EmojiStore from "discourse/services/emoji-store";
import type ModalService from "discourse/services/modal";
import dAutocomplete from "discourse/ui-kit/modifiers/d-autocomplete";
import { i18n } from "discourse-i18n";
import { enhanceWithin } from "../lib/disteleplus-voice-player.ts";
import DisteleplusService, {
  DisteleplusCurrentUser,
  DisteleplusMessage,
  DisteleplusSiteSettings,
  DisteleplusUserSummary,
  RawMessage,
  Reaction,
  ReadState,
  Typer,
} from "../services/disteleplus.ts";
import DisteleplusMessageInfo from "./disteleplus-message-info.gts";
import DisteleplusPoll from "./disteleplus-poll.gts";
import DisteleplusPollBuilder from "./disteleplus-poll-builder.gts";
import DisteleplusReactionInfo from "./disteleplus-reaction-info.gts";
import DisteleplusVoiceRecorder from "./disteleplus-voice-recorder.gts";

const EMOJI_CONTEXT = "disteleplus";
const DEFAULT_QUICK_REACTIONS = ["+1", "heart", "laughing", "fire", "tada"];
const MAX_UPLOADS = 10;
// Extra 40-message pages fetched on open to reach the unread divider.
const MAX_UNREAD_PAGES = 3;

interface DisteleplusConversationSignature {
  Args: { inDrawer?: boolean };
}

// The /uploads.json fields the composer keeps for a pending attachment.
interface ComposerUpload {
  id: number;
  original_filename: string;
}

interface ContextMenuState {
  message: DisteleplusMessage;
  x: number;
  y: number;
}

interface TimelineRow {
  kind: "date" | "unread" | "message";
  key: string | number;
  label?: string;
  message?: DisteleplusMessage;
  continued?: boolean;
}

interface QuickReaction {
  name: string;
  url: string;
}

interface AvatarChip {
  username: string;
  title?: string;
  url: string;
}

// A message or a reply preview — anything with an author to name.
interface Sendable {
  external_sender_name: string | null;
  user: DisteleplusUserSummary | null;
}

// The d-autocomplete options this composer passes.
interface ComposerAutocompleteOptions<T> {
  component: object;
  key: string;
  width?: string;
  autoSelectFirstSuggestion?: boolean;
  onKeyUp?: (text: string, caret: number) => string[] | undefined;
  transformComplete: (result: T) => string;
  dataSource: (term: string) => unknown;
  afterComplete: (text: string, event?: Event) => void;
}

interface UserSearchResult {
  username?: string;
  name?: string;
}

interface EmojiSearchResult {
  code: string;
  src?: string;
}

type AutocompleteInstance = ReturnType<typeof dAutocomplete.setupAutocomplete>;

// iPhone Safari only offers fullscreen on the video element itself.
type FullscreenVideo = HTMLVideoElement & {
  webkitEnterFullscreen?: () => void;
};

// Single-room conversation in Discourse Chat's visual language, with a
// right-click / ⋯ context menu per message, quick reactions plus the full
// core emoji picker, @mention and :emoji: autocomplete in the composer,
// paste/drag-drop uploads, a draft that survives navigation, and a lightbox
// for images.
export default class DisteleplusConversation extends Component<DisteleplusConversationSignature> {
  @service declare disteleplus: DisteleplusService;
  @service declare appEvents: AppEventsService;
  @service declare dialog: DialogService;
  @service declare menu: MenuService;
  @service declare modal: ModalService;
  @service declare emojiStore: EmojiStore;
  @service declare composer: ComposerService;
  @service declare siteSettings: DisteleplusSiteSettings;
  @service declare site: Site;
  @service declare router: RouterService;
  @service declare currentUser: DisteleplusCurrentUser | null;

  @tracked uploads: ComposerUpload[] = [];
  @tracked uploading = false;
  @tracked replyMessage: DisteleplusMessage | null = null;
  @tracked editingMessage: DisteleplusMessage | null = null;
  @tracked newBelow = 0;
  @tracked showJump = false;
  @tracked dragging = false;
  @tracked recordingVoice = false;
  // { message, x, y } while a context menu is open.
  @tracked contextMenu: ContextMenuState | null = null;

  element: HTMLElement | null = null;
  timeline: HTMLElement | null = null;
  textarea: HTMLTextAreaElement | null = null;
  unsubscribe: (() => boolean) | null = null;

  declare cancelOpenPin: (() => void) | null | undefined;

  // images rendered later (realtime, older pages) get handlers too.
  lightboxUploads = modifier((element: HTMLElement) => {
    if (element.querySelector(".lightbox")) {
      lightbox(element, this.siteSettings);
    }
  });

  // imperatively on insert rather than as a template modifier.
  autocompletes: AutocompleteInstance[] = [];

  // The estimates above pre-position the menu; the real box (the reactions
  // row makes it wider than any guess) is measured once rendered and pushed
  // back inside the conversation bounds.
  clampContextMenu = modifier((element: HTMLElement) => {
    const bounds = this.element.getBoundingClientRect();
    const rect = element.getBoundingClientRect();
    const overRight = rect.right - (bounds.right - 8);
    const overBottom = rect.bottom - (bounds.bottom - 8);
    if (overRight > 0) {
      element.style.left = `${Math.max(8, parseFloat(element.style.left) - overRight)}px`;
    }
    if (overBottom > 0) {
      element.style.top = `${Math.max(8, parseFloat(element.style.top) - overBottom)}px`;
    }
  });

  // Arrow property: the template calls this as a bare function helper, which
  // strips the receiver — a plain method would crash on this.avatarUrl.
  listenAvatars = (message: DisteleplusMessage): AvatarChip[] => {
    return (message.listened_by || []).slice(0, 8).map((user) => ({
      username: user.username,
      url: this.avatarUrl(user.avatar_template),
    }));
  };

  willDestroy() {
    super.willDestroy();
    this.cancelOpenPin?.();
    this.teardownAutocomplete();
    this.unsubscribe?.();
    document.removeEventListener("click", this.closeContextMenu);
    document.removeEventListener("keydown", this.onDocumentKeydown);
    window.removeEventListener("hashchange", this.onHashChange);
    this.appEvents.off("disteleplus:jump-to-message", this, this.jumpToId);
    this.disteleplus.setViewing(false);
  }

  get draft(): string {
    return this.disteleplus.draft;
  }

  get cannotSend(): boolean {
    return (
      this.disteleplus.sending ||
      this.uploading ||
      (!this.draft.trim() && this.uploads.length === 0)
    );
  }

  get quickReactions(): QuickReaction[] {
    let favorites: string[];
    try {
      favorites = this.emojiStore.favoritesForContext(EMOJI_CONTEXT) || [];
    } catch {
      favorites = [];
    }
    const names = [...favorites, ...DEFAULT_QUICK_REACTIONS]
      .filter((name, index, list) => list.indexOf(name) === index)
      .slice(0, 6);
    return names.map((name) => ({ name, url: emojiUrlFor(name) }));
  }

  // Timeline rows: messages interleaved with date separators and, once, the
  // unread divider (after the read cursor as it stood when the page opened).
  get rows(): TimelineRow[] {
    const rows: TimelineRow[] = [];
    let lastDay: string | null = null;
    let dividerPlaced = false;
    let previous: DisteleplusMessage | null = null;
    const readId = this.disteleplus.openedAtReadId || 0;
    for (const message of this.disteleplus.messages) {
      const day = message.createdDate.toDateString();
      if (day !== lastDay) {
        previous = null;
        rows.push({
          kind: "date",
          key: `date-${day}`,
          label: this.day(message.createdDate),
        });
        lastDay = day;
      }
      if (!dividerPlaced && readId && message.id > readId && !message.mine) {
        rows.push({ kind: "unread", key: "unread" });
        dividerPlaced = true;
        previous = null;
      }
      // Same sender within five minutes: collapse avatar and name.
      const continued =
        previous &&
        previous.user?.id === message.user?.id &&
        previous.external_sender_name === message.external_sender_name &&
        message.createdDate.getTime() - previous.createdDate.getTime() <
          5 * 60 * 1000;
      rows.push({ kind: "message", key: message.id, message, continued });
      previous = message;
    }
    return rows;
  }

  get nearBottom(): boolean {
    const element = this.timeline;
    if (!element) {
      return true;
    }
    return (
      element.scrollHeight - element.scrollTop - element.clientHeight < 100
    );
  }

  get contextMenuStyle(): SafeString {
    if (!this.contextMenu) {
      return htmlSafe("");
    }
    return htmlSafe(
      `left:${Math.round(this.contextMenu.x)}px;top:${Math.round(
        this.contextMenu.y
      )}px`
    );
  }

  get showFullPageNavbar(): boolean {
    return !this.args.inDrawer && !this.site.mobileView;
  }

  get voiceNotesEnabled(): boolean {
    return !!this.siteSettings.disteleplus_voice_notes_enabled;
  }

  get typingLabel(): string | null {
    const typers = this.disteleplus.typers;
    if (!typers.length) {
      return null;
    }
    const label = (t: Typer) => t.name || t.username;
    if (typers.length === 1) {
      return i18n("disteleplus.typing_one", { name: label(typers[0]) });
    }
    if (typers.length === 2) {
      return i18n("disteleplus.typing_two", {
        a: label(typers[0]),
        b: label(typers[1]),
      });
    }
    return i18n("disteleplus.typing_many", { count: typers.length });
  }

  // ── read receipts ─────────────────────────────────────────────────────────
  // Telegram-style: the chip lives on the current user's latest message
  // only — once a reader's cursor passes it, everything above is seen by
  // definition.

  get receiptMessageId(): number | null {
    if (!this.disteleplus.readReceiptsEnabled) {
      return null;
    }
    const messages = this.disteleplus.messages;
    for (let i = messages.length - 1; i >= 0; i--) {
      if (messages[i].mine && !messages[i].deleted) {
        return messages[i].id;
      }
    }
    return null;
  }

  get receiptSeenBy(): ReadState[] {
    const id = this.receiptMessageId;
    return id ? this.disteleplus.seenBy(id) : [];
  }

  get receiptAvatars(): AvatarChip[] {
    return this.receiptSeenBy.slice(0, 8).map((state) => ({
      username: state.username,
      title: state.name || state.username,
      url: this.avatarUrl(state.avatar_template),
    }));
  }

  get receiptTitle(): string {
    const names = this.receiptSeenBy.map(
      (state) => state.name || state.username
    );
    return names.join(", ");
  }

  // Chat's navbar OpenDrawerButton: leave full page, continue in the drawer.
  @action
  async openInDrawer() {
    this.disteleplus.prefersDrawer();
    const url = this.disteleplus.lastAppURL || "/";
    try {
      await this.router.transitionTo(url);
    } catch {
      // TransitionAborted is expected when another transition supersedes it.
    }
    this.disteleplus.openDrawer();
  }

  // ── lifecycle ─────────────────────────────────────────────────────────────

  @action
  mount(element: HTMLElement) {
    this.element = element;
    this.timeline = element.querySelector<HTMLElement>(".disteleplus-timeline");
    this.disteleplus.setViewing(true);
    this.unsubscribe = this.disteleplus.onNewMessage(this.onNewMessage);
    document.addEventListener("click", this.closeContextMenu);
    document.addEventListener("keydown", this.onDocumentKeydown);
    // A notification clicked while the conversation is already open only
    // changes the hash / fires the jump event — no remount happens.
    window.addEventListener("hashchange", this.onHashChange);
    this.appEvents.on("disteleplus:jump-to-message", this, this.jumpToId);
    element.addEventListener("disteleplus:voice-played", this.onVoicePlayed);
    requestAnimationFrame(() => {
      this.openAtStart();
      this.enhance(element);
    });
  }

  // Deep link (#m123, or one stashed by the route/drawer opener) wins;
  // otherwise land on the unread divider like Telegram does; otherwise the
  // bottom.
  async openAtStart(): Promise<void> {
    const match = window.location.hash.match(/^#m(\d+)$/);
    const targetId =
      this.disteleplus.consumePendingJump() || (match && Number(match[1]));
    if (targetId && (await this.jumpToId(targetId))) {
      return;
    }
    // The drawer renders this component before the first fetch resolves, so
    // the timeline can still be empty here. Scrolling it now would stick at
    // the top once the rows land, and nothing re-runs this after the load.
    const wasLoaded = this.disteleplus.loaded;
    try {
      await this.disteleplus.ensureLoaded();
    } catch {
      return;
    }
    if (this.isDestroying) {
      return;
    }
    if (!wasLoaded) {
      await new Promise((resolve) => requestAnimationFrame(resolve));
      this.enhance(this.timeline);
      // setViewing(true) ran on mount with nothing loaded, so its markRead
      // was a no-op; catch up the way an already-loaded open would have.
      this.disteleplus.markRead();
    }
    if (await this.scrollToUnread()) {
      return;
    }
    this.scrollToBottom();
    this.pinWhileMediaSettles();
  }

  // Land on the unread divider. The first page is only the newest
  // PAGE_SIZE messages, so with more unread than that the divider would sit
  // at the very top of the list with no context above it — page back until
  // the read cursor is inside the loaded slice (within reason) first.
  async scrollToUnread(): Promise<boolean> {
    const readId = this.disteleplus.openedAtReadId;
    if (!readId || !this.disteleplus.messages.length) {
      return false;
    }
    for (let page = 0; page < MAX_UNREAD_PAGES; page++) {
      if (
        this.disteleplus.messages[0].id <= readId ||
        !this.disteleplus.hasMore
      ) {
        break;
      }
      try {
        await this.disteleplus.loadOlder();
      } catch {
        break;
      }
      if (this.isDestroying) {
        return true;
      }
    }
    await new Promise((resolve) => requestAnimationFrame(resolve));
    const divider = this.timeline?.querySelector(
      ".disteleplus-separator.is-unread"
    );
    if (!divider) {
      return false;
    }
    this.enhance(this.timeline);
    divider.scrollIntoView({ block: "start", behavior: "instant" });
    this.showJump = !this.nearBottom;
    return true;
  }

  // Images, voice players and oneboxes finish layout AFTER the opening
  // scroll has landed and push the bottom out of view — hold the pin until
  // the layout stops moving, a few seconds pass, or the user takes over.
  pinWhileMediaSettles(): void {
    const el = this.timeline;
    if (!el || typeof ResizeObserver === "undefined") {
      return;
    }
    this.cancelOpenPin?.();
    const observer = new ResizeObserver(() => {
      this.setScrollTop(el, el.scrollHeight);
    });
    const cancel = () => {
      observer.disconnect();
      el.removeEventListener("wheel", cancel);
      el.removeEventListener("touchstart", cancel);
      clearTimeout(timer);
      this.cancelOpenPin = null;
    };
    [...el.children].forEach((child) => observer.observe(child));
    el.addEventListener("wheel", cancel, { passive: true });
    el.addEventListener("touchstart", cancel, { passive: true });
    const timer = setTimeout(cancel, 3000);
    this.cancelOpenPin = cancel;
  }

  @action
  onHashChange() {
    const match = window.location.hash.match(/^#m(\d+)$/);
    if (match) {
      this.jumpToId(Number(match[1]));
    }
  }

  // The timeline sets `scroll-behavior: smooth`, so assigning scrollTop
  // animates: the scroll starts at the top and fires scroll events all the
  // way down. onScroll's load-older check (scrollTop <= 100) trips on the
  // way past, and its restore then overrides the in-flight animation and
  // parks the reader at the top of the batch it just paged in. Every
  // programmatic scroll therefore has to be instant.
  setScrollTop(element: HTMLElement, top: number): void {
    element.scrollTo({ top, behavior: "instant" });
  }

  // Scroll to and highlight a message by id, fetching a window around it
  // when it isn't in the loaded slice. Resolves true when the message was
  // found (locally or remotely).
  @action
  async jumpToId(id: number): Promise<boolean> {
    // Consume a matching stash so a later mount doesn't replay the jump.
    if (this.disteleplus.pendingJumpId === id) {
      this.disteleplus.consumePendingJump();
    }
    if (!this.messageElement(id)) {
      try {
        await this.disteleplus.loadAround(id);
      } catch {
        return false;
      }
      await new Promise((resolve) => requestAnimationFrame(resolve));
      this.enhance(this.timeline);
    }
    const target = this.messageElement(id);
    if (!target) {
      return false;
    }
    this.highlight(target);
    this.showJump = !this.nearBottom;
    return true;
  }

  enhance(root: ParentNode | null): void {
    enhanceWithin(root, {
      allAudio: !!this.siteSettings.disteleplus_voice_player_all_audio,
    });
  }

  @action
  onNewMessage(message: DisteleplusMessage, { mine }: { mine: boolean }) {
    if (mine || this.nearBottom) {
      requestAnimationFrame(() => this.scrollToBottom());
    } else {
      this.newBelow += 1;
    }
    requestAnimationFrame(() => this.enhance(this.timeline));
  }

  // ── composer ──────────────────────────────────────────────────────────────

  @action
  updateDraft(event: Event) {
    const textarea = event.target as HTMLTextAreaElement;
    this.disteleplus.setDraft(textarea.value);
    this.autosize(textarea);
    if (textarea.value.trim()) {
      this.disteleplus.sendTyping();
    }
  }

  // Telegram-style double tap: react with your first quick reaction.
  // Touch only — on desktop a double-click usually means selecting a word,
  // and reacting on it reads as a misfire.
  @action
  doubleTap(message: DisteleplusMessage, event: MouseEvent) {
    if (!this.site.mobileView) {
      return;
    }
    if (message.deleted) {
      return;
    }
    if (
      (event.target as Element).closest(
        "a, button, audio, video, img, .lightbox"
      )
    ) {
      return;
    }
    event.preventDefault();
    const emoji = this.quickReactions[0]?.name || "heart";
    const el = this.messageElement(message.id);
    el?.classList.add("is-pop");
    window.setTimeout(() => el?.classList.remove("is-pop"), 600);
    this.react(message, emoji);
  }

  // ── search ────────────────────────────────────────────────────────────────

  @action
  toggleSearch() {
    this.disteleplus.toggleSearch();
    if (this.disteleplus.searchOpen) {
      requestAnimationFrame(() =>
        this.element
          ?.querySelector<HTMLInputElement>(".disteleplus-search input")
          ?.focus()
      );
    }
  }

  @action
  onSearchInput(event: Event) {
    this.disteleplus
      .search((event.target as HTMLInputElement).value)
      .catch(popupAjaxError);
  }

  @action
  onSearchKeydown(event: KeyboardEvent) {
    if (event.key === "Escape") {
      this.disteleplus.toggleSearch(false);
    }
  }

  @action
  async openResult(result: DisteleplusMessage) {
    this.disteleplus.toggleSearch(false);
    await this.jumpToId(result.id);
  }

  autosize(textarea: HTMLTextAreaElement): void {
    textarea.style.height = "auto";
    textarea.style.height = `${Math.min(textarea.scrollHeight, 200)}px`;
    // The scrollbar only exists once content outgrows the cap — otherwise a
    // fractional overflow paints Windows' arrow buttons in the 22px resting
    // composer (CSS keeps overflow-y hidden by default).
    textarea.style.overflowY =
      textarea.scrollHeight > textarea.clientHeight + 1 ? "auto" : "hidden";
  }

  @action
  composerKeydown(event: KeyboardEvent) {
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      // Let an open autocomplete menu take the Enter key.
      if (document.querySelector('[data-identifier="d-autocomplete"]')) {
        return;
      }
      event.preventDefault();
      this.send();
    } else if (
      event.key === "Escape" &&
      (this.replyMessage || this.editingMessage)
    ) {
      this.cancelContext();
    } else if (event.key === "ArrowUp" && !this.draft && !this.editingMessage) {
      // Telegram: up-arrow in an empty composer edits your last message.
      const mine = [...this.disteleplus.messages]
        .reverse()
        .find((message) => message.mine && message.can_edit);
      if (mine) {
        event.preventDefault();
        this.startEdit(mine);
      }
    }
  }

  @action
  async send() {
    if (this.cannotSend) {
      return;
    }
    try {
      if (this.editingMessage) {
        await this.disteleplus.updateMessage(
          this.editingMessage.id,
          this.draft.trim()
        );
      } else {
        await this.disteleplus.createMessage({
          raw: this.draft.trim(),
          uploadIds: this.uploads.map((upload) => upload.id),
          replyToId: this.replyMessage?.id,
        });
      }
      this.cancelContext();
      this.uploads = [];
      if (this.textarea) {
        this.textarea.style.height = "auto";
      }
      requestAnimationFrame(() => this.scrollToBottom());
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  startReply(message: DisteleplusMessage) {
    this.editingMessage = null;
    this.replyMessage = message;
    this.textarea?.focus();
  }

  @action
  startEdit(message: DisteleplusMessage) {
    this.replyMessage = null;
    this.editingMessage = message;
    this.disteleplus.setDraft(message.raw);
    requestAnimationFrame(() => {
      if (this.textarea) {
        this.autosize(this.textarea);
        this.textarea.focus();
        this.textarea.setSelectionRange(
          this.textarea.value.length,
          this.textarea.value.length
        );
      }
    });
  }

  @action
  cancelContext() {
    const wasEditing = !!this.editingMessage;
    this.replyMessage = null;
    this.editingMessage = null;
    if (wasEditing) {
      this.disteleplus.setDraft("");
    }
  }

  @action
  insertEmoji(event: MouseEvent) {
    this.menu.show(event.currentTarget as HTMLElement, {
      identifier: "disteleplus-emoji-picker",
      groupIdentifier: "emoji-picker",
      component: EmojiPickerDetached,
      modalForMobile: true,
      placement: "top-end",
      fallbackPlacements: ["top-start", "bottom-end"],
      data: {
        context: EMOJI_CONTEXT,
        didSelectEmoji: (emoji: string) => this.insertText(`:${emoji}: `),
      },
    });
  }

  insertText(text: string): void {
    const textarea = this.textarea;
    if (!textarea) {
      this.disteleplus.setDraft(`${this.draft}${text}`);
      return;
    }
    const start = textarea.selectionStart ?? textarea.value.length;
    const end = textarea.selectionEnd ?? start;
    const value = textarea.value;
    const next = value.slice(0, start) + text + value.slice(end);
    this.disteleplus.setDraft(next);
    requestAnimationFrame(() => {
      textarea.value = next;
      textarea.setSelectionRange(start + text.length, start + text.length);
      textarea.focus();
      this.autosize(textarea);
    });
  }

  // Autocomplete — wired exactly like Chat's composer: the modifier needs a
  // TextareaAutocompleteHandler as its textHandler, so it is set up

  @action
  setupComposerTextarea(textarea: HTMLTextAreaElement) {
    this.textarea = textarea;
    this.autosize(textarea);
    const handler = new TextareaAutocompleteHandler(textarea);
    const apply = <T,>(
      options: ComposerAutocompleteOptions<T>
    ): AutocompleteInstance =>
      dAutocomplete.setupAutocomplete(getOwner(this), textarea, handler, {
        treatAsTextarea: true,
        fixedTextareaPosition: true,
        ...options,
      });

    if (this.siteSettings.enable_mentions) {
      this.autocompletes.push(
        apply({
          component: UserAutocompleteResults,
          key: UserAutocompleteResults.TRIGGER_KEY,
          width: "100%",
          autoSelectFirstSuggestion: true,
          transformComplete: (result: UserSearchResult) => {
            validateSearchResult(result);
            return result.username || result.name;
          },
          dataSource: (term) => userSearch({ term, includeGroups: true }),
          afterComplete: (text, event) => {
            event?.preventDefault?.();
            this.disteleplus.setDraft(text);
            textarea.focus();
          },
        })
      );
    }

    if (this.siteSettings.enable_emoji) {
      this.autocompletes.push(
        apply({
          component: EmojiAutocompleteResults,
          key: EmojiAutocompleteResults.TRIGGER_KEY,
          onKeyUp: (text, caret) => {
            const matches =
              /(?:^|[\s.?,@/#!%&*;:[\]{}=\-_()+])(:(?!:).?[\w-]*:?(?!:)(?:t\d?)?:?)$/gi.exec(
                text.substring(0, caret)
              );
            return matches?.[1] ? [matches[1]] : undefined;
          },
          transformComplete: (result: EmojiSearchResult) => `${result.code}:`,
          dataSource: (term) => {
            if (!term || term.length < 2) {
              return [];
            }
            return emojiSearch(term, {
              maxResults: 6,
              diversity: this.emojiStore?.diversity,
            }).map(
              (code): EmojiSearchResult => ({ code, src: emojiUrlFor(code) })
            );
          },
          afterComplete: (text, event) => {
            event?.preventDefault?.();
            this.disteleplus.setDraft(text);
            textarea.focus();
          },
        })
      );
    }
  }

  teardownAutocomplete(): void {
    this.autocompletes.forEach((instance) => instance.cleanup?.());
    this.autocompletes = [];
  }

  // ── uploads ───────────────────────────────────────────────────────────────

  @action
  pickFiles(event: Event) {
    const input = event.target as HTMLInputElement;
    const files = [...input.files];
    input.value = "";
    this.addFiles(files);
  }

  @action
  onPaste(event: ClipboardEvent) {
    const files = [...(event.clipboardData?.files || [])];
    if (files.length) {
      event.preventDefault();
      this.addFiles(files);
    }
  }

  @action
  onDragOver(event: DragEvent) {
    if ([...(event.dataTransfer?.types || [])].includes("Files")) {
      event.preventDefault();
      this.dragging = true;
    }
  }

  @action
  onDragLeave(event: DragEvent) {
    if (!this.element?.contains(event.relatedTarget as Node | null)) {
      this.dragging = false;
    }
  }

  @action
  onDrop(event: DragEvent) {
    event.preventDefault();
    this.dragging = false;
    this.addFiles([...(event.dataTransfer?.files || [])]);
  }

  async addFiles(files: File[]): Promise<void> {
    if (!files.length) {
      return;
    }
    this.uploading = true;
    try {
      for (const file of files.slice(0, MAX_UPLOADS - this.uploads.length)) {
        const form = new FormData();
        form.append("type", "composer");
        form.append("file", file, file.name);
        const response: ComposerUpload = await ajax("/uploads.json", {
          type: "POST",
          data: form,
          processData: false,
          contentType: false,
        });
        this.uploads = [...this.uploads, response];
      }
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.uploading = false;
    }
  }

  @action
  removeUpload(upload: ComposerUpload) {
    // By object, not id: Discourse dedupes identical files to one upload id,
    // so attaching the same picture twice gives two rows with equal ids —
    // an id filter removed both when either X was clicked.
    this.uploads = this.uploads.filter((candidate) => candidate !== upload);
  }

  @action
  openVoiceRecorder() {
    this.teardownAutocomplete();
    this.recordingVoice = true;
  }

  @action
  closeVoiceRecorder() {
    this.recordingVoice = false;
    requestAnimationFrame(() => this.textarea?.focus());
  }

  @action
  voiceNoteSent(message: RawMessage | undefined) {
    this.recordingVoice = false;
    if (message) {
      this.disteleplus.upsert(message);
    }
    requestAnimationFrame(() => this.scrollToBottom());
  }

  // Same as Chat's message collapser: init the lightbox per uploads block so

  // ── message actions ───────────────────────────────────────────────────────

  @action
  openContextMenu(message: DisteleplusMessage, event: MouseEvent) {
    event.preventDefault();
    event.stopPropagation();
    const bounds = this.element.getBoundingClientRect();
    let x = event.clientX - bounds.left;
    let y = event.clientY - bounds.top;
    if (event.type !== "contextmenu") {
      // Anchored under the ⋯ button instead of the pointer.
      const rect = (event.currentTarget as Element).getBoundingClientRect();
      x = rect.right - bounds.left;
      y = rect.bottom - bounds.top;
    }
    x = Math.min(x, bounds.width - 230);
    y = Math.min(y, bounds.height - 320);
    this.contextMenu = { message, x: Math.max(8, x), y: Math.max(8, y) };
  }

  @action
  closeContextMenu() {
    this.contextMenu = null;
  }

  @action
  onDocumentKeydown(event: KeyboardEvent) {
    if (event.key === "Escape" && this.contextMenu) {
      this.closeContextMenu();
    }
  }

  @action
  async react(message: DisteleplusMessage, emoji: string) {
    this.closeContextMenu();
    try {
      this.emojiStore?.trackEmojiForContext?.(emoji, EMOJI_CONTEXT);
      await this.disteleplus.toggleReaction(message, emoji);
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  pickReaction(message: DisteleplusMessage, event: MouseEvent) {
    event.stopPropagation();
    this.closeContextMenu();
    // Anchor to the message row, not the button: the hover toolbar is
    // invisible when the pointer leaves it and the context menu is removed
    // from the DOM the moment it closes — both make useless anchors.
    const anchor =
      this.messageElement(message.id) || (event.currentTarget as HTMLElement);
    this.menu.show(anchor, {
      identifier: "disteleplus-reaction-picker",
      groupIdentifier: "emoji-picker",
      component: EmojiPickerDetached,
      modalForMobile: true,
      placement: "top-start",
      fallbackPlacements: ["bottom-start", "top-end", "bottom-end"],
      data: {
        context: EMOJI_CONTEXT,
        didSelectEmoji: (emoji: string) => this.react(message, emoji),
      },
    });
  }

  @action
  copyText(message: DisteleplusMessage) {
    this.closeContextMenu();
    clipboardCopy(message.raw || "");
  }

  @action
  copyLink(message: DisteleplusMessage) {
    this.closeContextMenu();
    clipboardCopy(`${getAbsoluteURL("/disteleplus")}#m${message.id}`);
  }

  @action
  quoteInTopic(message: DisteleplusMessage) {
    this.closeContextMenu();
    const author = this.sender(message);
    const body = `[quote="${author}"]\n${message.raw}\n[/quote]\n\n`;
    this.composer.openNewTopic({ body });
  }

  @action
  remove(message: DisteleplusMessage) {
    this.closeContextMenu();
    this.dialog.deleteConfirm({
      message: i18n("disteleplus.delete_confirm"),
      didConfirm: async () => {
        try {
          await this.disteleplus.deleteMessage(message.id);
        } catch (error) {
          popupAjaxError(error);
        }
      },
    });
  }

  @action
  menuReply(message: DisteleplusMessage) {
    this.closeContextMenu();
    this.startReply(message);
  }

  @action
  menuEdit(message: DisteleplusMessage) {
    this.closeContextMenu();
    this.startEdit(message);
  }

  // ── scrolling ─────────────────────────────────────────────────────────────

  @action
  async onScroll(event: Event) {
    const element = event.currentTarget as HTMLElement;
    const nearBottom =
      element.scrollHeight - element.scrollTop - element.clientHeight < 100;
    this.showJump = !nearBottom;
    if (nearBottom) {
      this.newBelow = 0;
      this.disteleplus.markRead();
    }
    if (element.scrollTop > 100 || !this.disteleplus.hasMore) {
      return;
    }

    const oldHeight = element.scrollHeight;
    const older = await this.disteleplus.loadOlder();
    if (older.length) {
      requestAnimationFrame(() => {
        this.setScrollTop(element, element.scrollHeight - oldHeight);
        this.enhance(element);
      });
    }
  }

  @action
  async scrollToBottom() {
    if (this.disteleplus.detached) {
      await this.disteleplus.reloadLatest();
      await new Promise((resolve) => requestAnimationFrame(resolve));
    }
    if (this.timeline) {
      this.setScrollTop(this.timeline, this.timeline.scrollHeight);
      this.newBelow = 0;
      this.showJump = false;
      this.disteleplus.markRead();
      this.enhance(this.timeline);
    }
  }

  @action
  jumpTo(message: { id: number }) {
    // jumpToId loads a window around out-of-view targets (old replies,
    // deep links) instead of silently doing nothing.
    this.jumpToId(message.id);
  }

  messageElement(id: number): HTMLElement | null {
    return document.getElementById(`disteleplus-message-${id}`);
  }

  highlight(target: HTMLElement): void {
    target.scrollIntoView({ behavior: "smooth", block: "center" });
    target.classList.add("is-highlighted");
    window.setTimeout(() => target.classList.remove("is-highlighted"), 1500);
  }

  // ── formatting helpers ────────────────────────────────────────────────────

  safeCooked(cooked: string | null): SafeString {
    return htmlSafe(cooked || "");
  }

  avatarUrl(template: string | null | undefined): string {
    return template?.replace("{size}", "48") || "";
  }

  day(date: Date): string {
    const today = new Date();
    const yesterday = new Date(today);
    yesterday.setDate(today.getDate() - 1);
    if (date.toDateString() === today.toDateString()) {
      return i18n("disteleplus.today");
    }
    if (date.toDateString() === yesterday.toDateString()) {
      return i18n("disteleplus.yesterday");
    }
    return new Intl.DateTimeFormat(undefined, {
      weekday: "short",
      month: "short",
      day: "numeric",
      year: date.getFullYear() === today.getFullYear() ? undefined : "numeric",
    }).format(date);
  }

  time(date: Date): string {
    return new Intl.DateTimeFormat(undefined, {
      hour: "numeric",
      minute: "2-digit",
    }).format(date);
  }

  bytes(value: number | null | undefined): string {
    const bytes = Number(value || 0);
    if (bytes < 1024 * 1024) {
      return `${Math.max(1, Math.round(bytes / 1024))} KB`;
    }
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }

  sender(message: Sendable): string {
    return (
      message.external_sender_name ||
      message.user?.name ||
      message.user?.username ||
      i18n("disteleplus.telegram_user")
    );
  }

  reactionTitle(reaction: Reaction): string {
    const names = (reaction.users || []).map(
      (user) => user.name || user.username
    );
    return names.length ? `:${reaction.emoji}: — ${names.join(", ")}` : "";
  }

  // "Listened by" tooltip for a voice-note message's receipt chip.
  listenTitle(message: DisteleplusMessage): string {
    return (message.listened_by || [])
      .map((user) => user.name || user.username)
      .join(", ");
  }

  // WhatsApp-style message info: who saw / listened, and when.
  @action
  openMessageInfo(message: DisteleplusMessage) {
    this.modal.show(DisteleplusMessageInfo, { model: { message } });
  }

  @action
  menuMessageInfo(message: DisteleplusMessage) {
    this.closeContextMenu();
    this.openMessageInfo(message);
  }

  // The native control bar has a fullscreen toggle too, but it is tiny and
  // some browsers tuck it behind an overflow menu — an explicit corner
  // button is discoverable. webkitEnterFullscreen covers iPhone Safari,
  // where element fullscreen only exists on the video itself.
  @action
  videoFullscreen(event: MouseEvent) {
    event.stopPropagation();
    const video: FullscreenVideo | null | undefined = (
      event.currentTarget as Element
    )
      .closest(".disteleplus-video-wrap")
      ?.querySelector("video");
    if (!video) {
      return;
    }
    if (video.requestFullscreen) {
      video.requestFullscreen();
    } else if (video.webkitEnterFullscreen) {
      video.webkitEnterFullscreen();
    }
  }

  @action
  openPollBuilder() {
    this.modal.show(DisteleplusPollBuilder, {
      model: {
        onCreate: async (markup: string) => {
          try {
            await this.disteleplus.createMessage({ raw: markup });
          } catch (error) {
            popupAjaxError(error);
          }
        },
      },
    });
  }

  // WhatsApp-style reactions sheet: who reacted with what and when; your own
  // rows remove on click, and "+" opens the picker for a new one.
  @action
  openReactionInfo(message: DisteleplusMessage) {
    // Resolve the message fresh on every action: bus updates replace the
    // objects wholesale, and toggleReaction decides add-vs-remove from the
    // reactions on the object it is handed — a stale capture would keep
    // adding forever.
    const current = () =>
      this.disteleplus.messages.find((m) => m.id === message.id) || message;
    this.modal.show(DisteleplusReactionInfo, {
      model: {
        message,
        react: (emoji: string) => this.react(current(), emoji),
        pick: (event: MouseEvent) => this.pickReaction(current(), event),
      },
    });
  }

  // Bubbled from the voice player on first play — record the receipt.
  @action
  onVoicePlayed(event: Event) {
    const wrapper = (event.target as Element).closest(
      "[id^='disteleplus-message-']"
    );
    const id = Number(wrapper?.id?.replace("disteleplus-message-", ""));
    if (id) {
      this.disteleplus.markListened(id);
    }
  }

  <template>
    <section
      class="disteleplus-page
        {{if @inDrawer 'in-drawer' 'full-page'}}
        {{if this.showFullPageNavbar 'has-navbar'}}
        {{if this.dragging 'is-dragging'}}"
      {{didInsert this.mount}}
      {{on "dragover" this.onDragOver}}
      {{on "dragleave" this.onDragLeave}}
      {{on "drop" this.onDrop}}
    >
      {{#if this.showFullPageNavbar}}
        <div class="disteleplus-navbar-container">
          <nav class="disteleplus-navbar">
            <div class="disteleplus-navbar__title">
              {{icon "comments"}}
              <span>{{i18n "disteleplus.title"}}</span>
            </div>
            <div class="disteleplus-navbar__actions">
              <DButton
                class="btn-transparent no-text
                  {{if this.disteleplus.searchOpen 'active'}}"
                @action={{this.toggleSearch}}
                @icon="magnifying-glass"
                @title="disteleplus.search"
              />
              <DButton
                class="btn-transparent no-text"
                @action={{this.openInDrawer}}
                @icon="discourse-compress"
                @title="disteleplus.open_in_drawer"
              />
            </div>
          </nav>
        </div>
      {{/if}}
      {{#if this.disteleplus.searchOpen}}
        <div class="disteleplus-search">
          <div class="disteleplus-search__bar">
            {{icon "magnifying-glass"}}
            <input
              placeholder={{i18n "disteleplus.search_placeholder"}}
              type="search"
              value={{this.disteleplus.searchTerm}}
              {{on "input" this.onSearchInput}}
              {{on "keydown" this.onSearchKeydown}}
            />
            <button
              title={{i18n "disteleplus.close"}}
              type="button"
              {{on "click" this.toggleSearch}}
            >{{icon "xmark"}}</button>
          </div>
          {{#if this.disteleplus.searchResults}}
            <div class="disteleplus-search__results">
              {{#each this.disteleplus.searchResults as |result|}}
                <button
                  class="disteleplus-search__result"
                  type="button"
                  {{on "click" (fn this.openResult result)}}
                >
                  <strong>{{this.sender result}}</strong>
                  <time>{{this.day result.createdDate}}
                    {{this.time result.createdDate}}</time>
                  <span>{{this.safeCooked result.cooked}}</span>
                </button>
              {{else}}
                <div class="disteleplus-search__empty">{{i18n
                    "disteleplus.search_empty"
                  }}</div>
              {{/each}}
            </div>
          {{/if}}
        </div>
      {{/if}}

      <div class="disteleplus-timeline" {{on "scroll" this.onScroll}}>
        {{#if this.disteleplus.loadingOlder}}
          <div class="disteleplus-loading">{{i18n "disteleplus.loading"}}</div>
        {{/if}}

        {{#each this.rows key="key" as |row|}}
          {{#if (eq row.kind "date")}}
            <div class="disteleplus-separator is-date"><span
              >{{row.label}}</span></div>
          {{else if (eq row.kind "unread")}}
            <div class="disteleplus-separator is-unread"><span>{{i18n
                  "disteleplus.unread_divider"
                }}</span></div>
          {{else}}
            {{#let row.message as |message|}}
              {{! eslint-disable ember/template-no-invalid-interactive }}
              <article
                class="disteleplus-message
                  {{if message.mine 'is-mine'}}
                  {{if message.deleted 'is-deleted'}}
                  {{if message.edited_at 'is-edited'}}
                  {{if row.continued 'is-continued'}}
                  {{if
                    (eq this.contextMenu.message.id message.id)
                    'is-menu-open'
                  }}"
                id="disteleplus-message-{{message.id}}"
                {{on "contextmenu" (fn this.openContextMenu message)}}
                {{on "dblclick" (fn this.doubleTap message)}}
              >
                {{! Bare #m<id> anchor so /disteleplus#m42 also works through
                    core's jumpToElement and native browser anchoring. }}
                <span
                  aria-hidden="true"
                  class="disteleplus-message__hash-anchor"
                  id="m{{message.id}}"
                ></span>
                <div class="disteleplus-message__avatar">
                  {{#if message.user}}
                    <a
                      data-user-card={{message.user.username}}
                      href="/u/{{message.user.username}}"
                    >
                      <img
                        alt=""
                        height="36"
                        src={{this.avatarUrl message.user.avatar_template}}
                        width="36"
                      />
                    </a>
                  {{else}}
                    {{icon "paper-plane"}}
                  {{/if}}
                </div>
                <div class="disteleplus-message__bubble">
                  <div class="disteleplus-message__meta">
                    <strong>{{this.sender message}}</strong>
                    <span class="disteleplus-message__time">
                      {{#if message.edited_at}}<small>{{i18n
                            "disteleplus.edited"
                          }}</small>{{/if}}
                      <time>{{this.time message.createdDate}}</time>
                    </span>
                  </div>

                  {{#if message.reply_to}}
                    <button
                      class="disteleplus-message__reply-preview"
                      type="button"
                      {{on "click" (fn this.jumpTo message.reply_to)}}
                    >
                      {{#if message.reply_to.thumbnail_url}}
                        <img
                          alt=""
                          class="disteleplus-message__reply-thumb"
                          src={{message.reply_to.thumbnail_url}}
                        />
                      {{/if}}
                      <span class="disteleplus-message__reply-text">
                        <strong>{{this.sender message.reply_to}}</strong>
                        {{#if message.reply_to.deleted}}
                          <span>{{i18n "disteleplus.deleted"}}</span>
                        {{else if message.reply_to.excerpt}}
                          <span>{{message.reply_to.excerpt}}</span>
                        {{else if message.reply_to.attachment_name}}
                          <span>{{icon "paperclip"}}
                            {{message.reply_to.attachment_name}}</span>
                        {{/if}}
                      </span>
                    </button>
                  {{/if}}

                  {{#if message.deleted}}
                    <p class="disteleplus-message__deleted">{{icon "trash-can"}}
                      {{i18n "disteleplus.deleted"}}</p>
                  {{else}}
                    {{#if message.uploads.length}}
                      <div class="disteleplus-uploads" {{this.lightboxUploads}}>
                        {{#each message.uploads as |upload|}}
                          {{#if (eq upload.kind "image")}}
                            <img
                              alt={{upload.original_filename}}
                              class="disteleplus-upload is-image lightbox"
                              data-download-href={{upload.url}}
                              data-large-src={{upload.url}}
                              data-target-height={{upload.height}}
                              data-target-width={{upload.width}}
                              height={{upload.height}}
                              loading="lazy"
                              src={{upload.url}}
                              tabindex="0"
                              title={{upload.original_filename}}
                              width={{upload.width}}
                            />
                          {{else if (eq upload.kind "video")}}
                            <span class="disteleplus-video-wrap">
                              <video
                                class="disteleplus-upload is-video"
                                controls
                                preload="metadata"
                              >
                                <source src={{upload.url}} />
                              </video>
                              <button
                                aria-label={{i18n
                                  "disteleplus.player.fullscreen"
                                }}
                                class="disteleplus-video-fullscreen"
                                title={{i18n "disteleplus.player.fullscreen"}}
                                type="button"
                                {{on "click" this.videoFullscreen}}
                              >
                                {{icon "discourse-expand"}}
                              </button>
                            </span>
                          {{else if (eq upload.kind "audio")}}
                            <div class="disteleplus-upload is-audio">
                              <audio
                                controls
                                data-voice={{if upload.voice "1"}}
                                preload="metadata"
                                src={{upload.url}}
                              ></audio>
                            </div>
                          {{else}}
                            <a
                              class="disteleplus-upload is-document"
                              download={{upload.original_filename}}
                              href={{upload.url}}
                            >
                              <span class="disteleplus-upload__icon">{{icon
                                  "file"
                                }}</span>
                              <span class="disteleplus-upload__text"><strong
                                >{{upload.original_filename}}</strong><small
                                >{{this.bytes upload.filesize}}</small></span>
                              {{icon "download"}}
                            </a>
                          {{/if}}
                        {{/each}}
                      </div>
                    {{/if}}

                    {{#if message.cooked}}
                      <div
                        class="disteleplus-message__cooked cooked
                          {{if message.poll 'has-poll'}}"
                      >
                        {{this.safeCooked message.cooked}}
                      </div>
                    {{/if}}
                  {{/if}}

                  {{#if message.poll}}
                    <DisteleplusPoll @message={{message}} />
                  {{/if}}

                  {{#if message.reactions.length}}
                    <div class="disteleplus-reactions">
                      {{#each message.reactions as |reaction|}}
                        <button
                          class={{if reaction.reacted "is-reacted"}}
                          title={{this.reactionTitle reaction}}
                          type="button"
                          {{on "click" (fn this.openReactionInfo message)}}
                        >
                          {{#if reaction.url}}
                            <img
                              alt=":{{reaction.emoji}}:"
                              class="emoji"
                              src={{reaction.url}}
                            />
                          {{else}}
                            {{reaction.display}}
                          {{/if}}
                          <span>{{reaction.count}}</span>
                        </button>
                      {{/each}}
                    </div>
                  {{/if}}

                  {{#if (eq message.id this.receiptMessageId)}}
                    <button
                      class="disteleplus-message__receipt
                        {{if this.receiptSeenBy.length 'is-seen'}}"
                      title={{this.receiptTitle}}
                      type="button"
                      {{on "click" (fn this.openMessageInfo message)}}
                    >
                      {{#if this.receiptSeenBy.length}}
                        {{icon "check-double"}}
                        <span class="disteleplus-message__receipt-label">
                          {{i18n
                            "disteleplus.seen_by"
                            count=this.receiptSeenBy.length
                          }}
                        </span>
                        <span class="disteleplus-message__receipt-avatars">
                          {{#each this.receiptAvatars as |reader|}}
                            <img
                              alt={{reader.username}}
                              src={{reader.url}}
                              title={{reader.title}}
                            />
                          {{/each}}
                        </span>
                      {{else}}
                        {{icon "check"}}
                      {{/if}}
                    </button>
                  {{/if}}

                  {{#if message.mine}}
                    {{#if message.listened_by.length}}
                      <button
                        class="disteleplus-message__receipt is-seen"
                        title={{this.listenTitle message}}
                        type="button"
                        {{on "click" (fn this.openMessageInfo message)}}
                      >
                        {{icon "headphones"}}
                        <span class="disteleplus-message__receipt-label">
                          {{i18n
                            "disteleplus.listened_by"
                            count=message.listened_by.length
                          }}
                        </span>
                        <span class="disteleplus-message__receipt-avatars">
                          {{#each (this.listenAvatars message) as |listener|}}
                            <img
                              alt={{listener.username}}
                              src={{listener.url}}
                              title={{listener.username}}
                            />
                          {{/each}}
                        </span>
                      </button>
                    {{/if}}
                  {{/if}}
                </div>

                {{#unless message.deleted}}
                  <div class="disteleplus-message__actions">
                    <button
                      title={{i18n "disteleplus.react"}}
                      type="button"
                      {{on "click" (fn this.pickReaction message)}}
                    >{{icon "face-smile"}}</button>
                    <button
                      title={{i18n "disteleplus.reply"}}
                      type="button"
                      {{on "click" (fn this.startReply message)}}
                    >{{icon "reply"}}</button>
                    <button
                      aria-haspopup="menu"
                      title={{i18n "disteleplus.more"}}
                      type="button"
                      {{on "click" (fn this.openContextMenu message)}}
                    >{{icon "ellipsis"}}</button>
                  </div>
                {{/unless}}
              </article>
            {{/let}}
          {{/if}}
        {{else}}
          <div class="disteleplus-empty">
            {{icon "comments"}}
            <h2>{{i18n "disteleplus.empty_title"}}</h2>
          </div>
        {{/each}}
      </div>

      {{#if this.contextMenu}}
        {{#let this.contextMenu.message as |message|}}
          <div
            class="disteleplus-context-menu"
            role="menu"
            style={{this.contextMenuStyle}}
            {{this.clampContextMenu}}
          >
            <div class="disteleplus-context-menu__reactions" role="group">
              {{#each this.quickReactions as |reaction|}}
                <button
                  role="menuitem"
                  title=":{{reaction.name}}:"
                  type="button"
                  {{on "click" (fn this.react message reaction.name)}}
                ><img
                    alt=":{{reaction.name}}:"
                    class="emoji"
                    src={{reaction.url}}
                  /></button>
              {{/each}}
              <button
                class="is-more"
                role="menuitem"
                title={{i18n "disteleplus.react"}}
                type="button"
                {{on "click" (fn this.pickReaction message)}}
              >{{icon "plus"}}</button>
            </div>
            <button
              role="menuitem"
              type="button"
              {{on "click" (fn this.menuReply message)}}
            >{{icon "reply"}} {{i18n "disteleplus.reply"}}</button>
            {{#if message.raw}}
              <button
                role="menuitem"
                type="button"
                {{on "click" (fn this.copyText message)}}
              >{{icon "copy"}} {{i18n "disteleplus.copy_text"}}</button>
            {{/if}}
            <button
              role="menuitem"
              type="button"
              {{on "click" (fn this.copyLink message)}}
            >{{icon "link"}} {{i18n "disteleplus.copy_link"}}</button>
            {{! Staff can inspect any message's views; others only their own. }}
            {{#if (or message.mine this.currentUser.staff)}}
              <button
                role="menuitem"
                type="button"
                {{on "click" (fn this.menuMessageInfo message)}}
              >{{icon "circle-info"}}
                {{i18n "disteleplus.message_info.title"}}</button>
            {{/if}}
            {{#if this.siteSettings.disteleplus_quote_in_topic_enabled}}
              {{#if message.raw}}
                <button
                  role="menuitem"
                  type="button"
                  {{on "click" (fn this.quoteInTopic message)}}
                >{{icon "quote-right"}}
                  {{i18n "disteleplus.quote_in_topic"}}</button>
              {{/if}}
            {{/if}}
            {{#if message.can_edit}}
              <button
                role="menuitem"
                type="button"
                {{on "click" (fn this.menuEdit message)}}
              >{{icon "pencil"}} {{i18n "disteleplus.edit"}}</button>
            {{/if}}
            {{#if message.can_delete}}
              <button
                class="is-danger"
                role="menuitem"
                type="button"
                {{on "click" (fn this.remove message)}}
              >{{icon "trash-can"}} {{i18n "disteleplus.delete"}}</button>
            {{/if}}
          </div>
        {{/let}}
      {{/if}}

      {{#if this.showJump}}
        <button
          aria-label={{i18n "disteleplus.go_to_bottom"}}
          class="disteleplus-jump"
          title={{i18n "disteleplus.go_to_bottom"}}
          type="button"
          {{on "click" this.scrollToBottom}}
        >
          {{icon "arrow-down"}}
          {{#if this.newBelow}}<span>{{this.newBelow}}</span>{{/if}}
        </button>
      {{/if}}

      {{#if this.dragging}}
        <div class="disteleplus-drop">{{icon "upload"}}
          {{i18n "disteleplus.drop_files"}}</div>
      {{/if}}

      <footer class="disteleplus-composer">
        <div class="disteleplus-typing">
          {{#if this.typingLabel}}
            <span class="disteleplus-typing__text">{{this.typingLabel}}</span>
            <span class="disteleplus-typing__wave"><span></span><span
              ></span><span></span></span>
          {{/if}}
        </div>
        {{#if (or this.replyMessage this.editingMessage)}}
          <div class="disteleplus-composer__context">
            {{icon (if this.editingMessage "pencil" "reply")}}
            <span>
              <strong>{{#if this.editingMessage}}{{i18n
                    "disteleplus.editing"
                  }}{{else}}{{this.sender this.replyMessage}}{{/if}}</strong>
              {{#if this.replyMessage}}
                <em>{{this.safeCooked this.replyMessage.cooked}}</em>
              {{/if}}
            </span>
            <button
              title={{i18n "disteleplus.cancel"}}
              type="button"
              {{on "click" this.cancelContext}}
            >{{icon "xmark"}}</button>
          </div>
        {{/if}}

        {{#if this.uploads.length}}
          <div class="disteleplus-composer__uploads">
            {{#each this.uploads as |upload|}}
              <span>{{icon "paperclip"}}
                {{upload.original_filename}}<button
                  title={{i18n "disteleplus.remove"}}
                  type="button"
                  {{on "click" (fn this.removeUpload upload)}}
                >{{icon "xmark"}}</button></span>
            {{/each}}
          </div>
        {{/if}}

        <div class="disteleplus-composer__row">
          {{#if this.recordingVoice}}
            <DisteleplusVoiceRecorder
              @onClose={{this.closeVoiceRecorder}}
              @onSent={{this.voiceNoteSent}}
            />
          {{else}}
            <div
              class="disteleplus-composer__input
                {{if this.cannotSend 'is-send-disabled' 'is-send-enabled'}}"
            >
              <label
                class="disteleplus-composer__button"
                title={{i18n "disteleplus.attach"}}
              >
                {{icon "plus"}}
                <input multiple type="file" {{on "change" this.pickFiles}} />
              </label>
              <textarea
                maxlength="20000"
                placeholder={{i18n "disteleplus.placeholder"}}
                rows="1"
                value={{this.draft}}
                {{on "input" this.updateDraft}}
                {{on "keydown" this.composerKeydown}}
                {{on "paste" this.onPaste}}
                {{didInsert this.setupComposerTextarea}}
              ></textarea>
              {{#if this.voiceNotesEnabled}}
                <button
                  aria-label={{i18n "disteleplus.voice.button"}}
                  class="disteleplus-composer__button"
                  title={{i18n "disteleplus.voice.button"}}
                  type="button"
                  {{on "click" this.openVoiceRecorder}}
                >
                  {{icon "microphone"}}
                </button>
              {{/if}}
              {{#if this.disteleplus.pollsEnabled}}
                <button
                  aria-label={{i18n "disteleplus.poll.builder.title"}}
                  class="disteleplus-composer__button"
                  title={{i18n "disteleplus.poll.builder.title"}}
                  type="button"
                  {{on "click" this.openPollBuilder}}
                >
                  {{icon "chart-simple"}}
                </button>
              {{/if}}
              <button
                aria-label={{i18n "disteleplus.emoji"}}
                class="disteleplus-composer__button"
                title={{i18n "disteleplus.emoji"}}
                type="button"
                {{on "click" this.insertEmoji}}
              >
                {{icon "face-smile"}}
              </button>
              <div class="disteleplus-composer__separator"></div>
              <button
                aria-label={{i18n "disteleplus.send"}}
                class="disteleplus-composer__button is-send"
                disabled={{this.cannotSend}}
                title={{i18n "disteleplus.send"}}
                type="button"
                {{on "click" this.send}}
              >
                {{#if (or this.disteleplus.sending this.uploading)}}
                  {{icon "spinner" class="fa-spin"}}
                {{else}}
                  {{icon "paper-plane"}}
                {{/if}}
              </button>
            </div>
          {{/if}}
        </div>
      </footer>
    </section>
  </template>
}
