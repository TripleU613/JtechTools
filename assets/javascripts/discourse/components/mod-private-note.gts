import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import { service } from "@ember/service";
import type { TrustedHTML } from "@ember/template";
import DButton from "discourse/components/d-button";
import type DialogService from "discourse/dialog-holder/services/dialog";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { cook } from "discourse/lib/text";
import type User from "discourse/models/user";
import type AppEventsService from "discourse/services/app-events";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import ModTopicMessagesModal, {
  type NoteAuthor,
  type TopicMessagesTopic,
} from "./mod-topic-messages-modal.gts";

interface NoteReply {
  id: string;
  raw: string;
  created_at: string | null;
  author: NoteAuthor | null;
}

interface NoteViewer {
  user_id: number;
  username: string;
  name: string | null;
  avatar_template: string | null;
  viewed_at: string | null;
}

export type PrivateNoteTopic = TopicMessagesTopic & {
  mod_topic_private_note_created_at?: string | null;
  mod_topic_private_note_replies?: NoteReply[];
  mod_topic_note_viewers?: NoteViewer[];
};

// The note-thread payload every note/reply action returns; the reply POST
// returns only `replies`.
interface NoteThreadResponse {
  private_note?: string;
  private_note_author?: NoteAuthor | null;
  private_note_created_at?: string | null;
  replies?: NoteReply[];
}

interface NoteViewersResponse {
  viewers?: NoteViewer[];
}

interface DecoratedViewer {
  userId: number;
  username: string;
  name: string;
  avatarUrl: string | null;
  agoLabel: string;
}

interface DecoratedReply {
  id: string;
  raw: string;
  cooked: TrustedHTML | null;
  agoLabel: string;
  authorName: string | null;
  avatarUrl: string | null;
  editing: boolean;
  canTouch: boolean;
}

interface PrivateNoteSiteSettings {
  mod_categories_enabled: boolean;
  mod_topic_private_notes_enabled: boolean;
  mod_note_view_tracking_enabled: boolean;
  mod_moderators_can_edit_others_notes: boolean;
}

type PrivateNoteUser = User & { admin?: boolean; username: string };

interface ModPrivateNoteSignature {
  Args: {
    topic: PrivateNoteTopic;
    place: "top" | "bottom";
  };
}

// Short relative-time label ("just now", "5m", "3h", "2d") for a note.
function timeAgo(iso: string | null | undefined): string {
  if (!iso) {
    return "";
  }
  const then = new Date(iso).getTime();
  if (isNaN(then)) {
    return "";
  }
  const seconds = Math.max(0, (Date.now() - then) / 1000);
  if (seconds < 60) {
    return i18n("discourse_mod_categories.private_note.just_now");
  }
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) {
    return `${minutes}m`;
  }
  const hours = Math.floor(minutes / 60);
  if (hours < 24) {
    return `${hours}h`;
  }
  return `${Math.floor(hours / 24)}d`;
}

function authorName(
  author: { name?: string | null; username: string } | null | undefined
): string | null {
  return author ? author.name || author.username : null;
}

function avatarUrl(
  author: { avatar_template?: string | null } | null | undefined
): string | null {
  const template = author?.avatar_template;
  return template ? template.replace("{size}", "45") : null;
}

// A staff-only note on a topic — and its thread of staff replies. Shown
// like posts (avatar, name, relative time). The note is serialized only
// to staff; this component also renders nothing unless the current user
// is staff. `@place` is "top" or "bottom".
//
// Staff can edit and delete individual entries — each reply, and the
// note body itself. The hosting plugin-outlet connector is reused across
// topic navigation, so all per-topic tracked state is re-read whenever
// `@topic.id` changes (via a `{{did-update}}` modifier).
export default class ModPrivateNote extends Component<ModPrivateNoteSignature> {
  @service declare appEvents: AppEventsService;
  @service declare currentUser: PrivateNoteUser | null;
  @service declare siteSettings: SiteSettings & PrivateNoteSiteSettings;
  @service declare dialog: DialogService;
  @service declare modal: ModalService;

  @tracked note = this.args.topic?.mod_topic_private_note || "";
  @tracked
  position: string =
    this.args.topic?.mod_topic_private_note_position || "bottom";
  @tracked
  author: NoteAuthor | null =
    this.args.topic?.mod_topic_private_note_author || null;
  @tracked
  createdAt: string | null =
    this.args.topic?.mod_topic_private_note_created_at || null;
  @tracked
  replies: NoteReply[] = this.args.topic?.mod_topic_private_note_replies || [];
  @tracked replying = false;
  @tracked replyText = "";
  @tracked saving = false;
  @tracked cookedNote: TrustedHTML | null = null;
  @tracked cookedReplies: TrustedHTML[] = [];
  // The id of the reply currently being edited inline, or null.
  @tracked editingReplyId: string | null = null;
  @tracked editText = "";
  // Staff who have viewed this mod-note panel (each is
  // `{user_id, username, name, avatar_template, viewed_at}`).
  @tracked
  viewers: NoteViewer[] = this.args.topic?.mod_topic_note_viewers || [];
  // Whether the "👁 Viewed by N" popover is open. Single popover at a
  // time per panel — clicking the pill toggles it.
  @tracked viewersPopoverOpen = false;

  constructor(owner: Owner, args: ModPrivateNoteSignature["Args"]) {
    super(owner, args);
    this.appEvents.on("discourse-mod:messages-updated", this, this.refresh);
    this.cookContent();
  }

  willDestroy() {
    super.willDestroy();
    this.appEvents.off("discourse-mod:messages-updated", this, this.refresh);
  }

  get sortedViewers(): NoteViewer[] {
    // Most recent first.
    return [...(this.viewers || [])].sort((a, b) => {
      const aTime = a?.viewed_at ? Date.parse(a.viewed_at) : 0;
      const bTime = b?.viewed_at ? Date.parse(b.viewed_at) : 0;
      return bTime - aTime;
    });
  }

  get decoratedViewers(): DecoratedViewer[] {
    return this.sortedViewers.map((v) => ({
      userId: v.user_id,
      username: v.username,
      name: v.name || v.username,
      avatarUrl: avatarUrl(v),
      agoLabel: timeAgo(v.viewed_at),
    }));
  }

  // Up to MAX_PILL_AVATARS small avatars rendered inline in the pill.
  // The rest go into the "+N" overflow indicator and remain accessible
  // via the popover.
  get pillViewers(): DecoratedViewer[] {
    return this.decoratedViewers.slice(0, 5);
  }

  get overflowCount(): number {
    return Math.max(0, this.decoratedViewers.length - 5);
  }

  get visible(): boolean {
    if (
      !this.siteSettings.mod_categories_enabled ||
      !this.siteSettings.mod_topic_private_notes_enabled
    ) {
      return false;
    }
    if (!this.currentUser?.staff) {
      return false;
    }
    if (!this.note || this.note.trim().length === 0) {
      return false;
    }
    const place = this.args.place === "top" ? "top" : "bottom";
    const chosen = this.position === "top" ? "top" : "bottom";
    return place === chosen;
  }

  get noteHtml(): TrustedHTML | null {
    return this.cookedNote;
  }

  get authorName(): string | null {
    return authorName(this.author);
  }

  get avatarUrl(): string | null {
    return avatarUrl(this.author);
  }

  get createdAgo(): string {
    return timeAgo(this.createdAt);
  }

  get canTouchNote(): boolean {
    return this.canTouchEntry(this.author);
  }

  get decoratedReplies(): DecoratedReply[] {
    return (this.replies || []).map((reply, index) => ({
      id: reply.id,
      raw: reply.raw,
      cooked: this.cookedReplies[index] || null,
      agoLabel: timeAgo(reply.created_at),
      authorName: authorName(reply.author),
      avatarUrl: avatarUrl(reply.author),
      editing: this.editingReplyId === reply.id,
      canTouch: this.canTouchEntry(reply.author),
    }));
  }

  // appEvent handler for live edits within the current topic. The guard
  // keeps a stale event for another topic from clobbering this one.
  refresh(topic: PrivateNoteTopic | null | undefined) {
    if (!topic || topic.id !== this.args.topic?.id) {
      return;
    }
    this.readTopicState(topic);
  }

  // Notifications and the user-menu notes feed link to the topic with a
  // `#mod-private-note` or `#mod-private-note-reply-<id>` hash. Without an
  // explicit scroll, Discourse's post-stream scrolls the linked post into
  // view AFTER the browser's native hash jump, leaving the target
  // off-screen — especially when the topic only has one post, which
  // silently lands at the top of the thread. Each reply article also
  // carries its own id so a reply notification anchors to that reply.
  @action
  scrollToNoteIfAnchored() {
    if (typeof window === "undefined") {
      return;
    }
    const hash = window.location.hash || "";
    if (
      hash !== "#mod-private-note" &&
      !hash.startsWith("#mod-private-note-reply-")
    ) {
      return;
    }
    // Defer past Discourse's own scroll-to-post on initial topic load,
    // and resolve the element after the replies finish rendering — a
    // per-reply hash may point at an article that isn't in the DOM yet
    // when the outer note container inserts.
    setTimeout(() => {
      const id = hash.slice(1);
      const target = document.getElementById(id);
      target?.scrollIntoView({ behavior: "smooth", block: "start" });
    }, 250);
  }

  // Re-read all per-topic state from the current topic. Called on initial
  // insert and whenever the connector is reused for a different topic.
  // Also records the current staff user as a viewer of this panel so
  // the "👁 Viewed by N" pill reflects them on the next paint.
  @action
  refreshOnNavigation() {
    this.readTopicState(this.args.topic);
    this.recordNoteView();
  }

  readTopicState(topic: PrivateNoteTopic | null | undefined) {
    this.note = topic?.mod_topic_private_note || "";
    this.position = topic?.mod_topic_private_note_position || "bottom";
    this.author = topic?.mod_topic_private_note_author || null;
    this.createdAt = topic?.mod_topic_private_note_created_at || null;
    this.replies = topic?.mod_topic_private_note_replies || [];
    this.viewers = topic?.mod_topic_note_viewers || [];
    this.viewersPopoverOpen = false;
    this.replying = false;
    this.replyText = "";
    this.editingReplyId = null;
    this.editText = "";
    this.cookContent();
  }

  // Pings the server to record the current user as a viewer of this
  // mod-note panel. Idempotent — re-views update `viewed_at` on the
  // existing entry. Fires once per topic navigation via the same
  // `didInsert` modifier the scroll-on-hash uses.
  @action
  async recordNoteView() {
    if (!this.siteSettings.mod_note_view_tracking_enabled) {
      return;
    }
    if (!this.visible) {
      return;
    }
    try {
      const result: NoteViewersResponse | null = await ajax(
        `/discourse-mod-categories/topic/${this.args.topic.id}/note-view`,
        { type: "POST" }
      );
      this.viewers = result?.viewers || [];
      this.args.topic.set("mod_topic_note_viewers", this.viewers);
    } catch {
      // Best-effort — failing to record a view shouldn't block the
      // panel from rendering. The pill just won't update to include
      // the current user; the next render will pick it up.
    }
  }

  @action
  toggleViewersPopover() {
    this.viewersPopoverOpen = !this.viewersPopoverOpen;
  }

  // Cooks the raw note markdown and each reply body asynchronously. The
  // stored/edited values stay raw — only the display is cooked.
  async cookContent(): Promise<void> {
    const note = this.note;
    if (note && note.trim().length > 0) {
      const cooked: TrustedHTML = await cook(note, undefined);
      if (this.note === note) {
        this.cookedNote = cooked;
      }
    } else {
      this.cookedNote = null;
    }

    const replies = this.replies || [];
    const cooked: TrustedHTML[] = await Promise.all(
      replies.map((reply) => cook(reply.raw || "", undefined))
    );
    if (this.replies === replies) {
      this.cookedReplies = cooked;
    }
  }

  // Mirrors the server's ownership rule (messages_controller
  // ensure_can_touch_note_entry!): the entry's author, admins, or any
  // moderator when the site opts into cross-staff editing. Rendering the
  // buttons to everyone used to invite a guaranteed 403.
  canTouchEntry(author: NoteAuthor | null | undefined): boolean {
    if (this.currentUser?.admin) {
      return true;
    }
    if (this.siteSettings.mod_moderators_can_edit_others_notes) {
      return true;
    }
    return !!author?.username && author.username === this.currentUser?.username;
  }

  // Applies a note-thread response (note body + replies) to local state.
  applyThread(result: NoteThreadResponse) {
    if (result.private_note !== undefined) {
      this.note = result.private_note || "";
      this.args.topic.set("mod_topic_private_note", this.note);
    }
    if (result.private_note_author !== undefined) {
      this.author = result.private_note_author || null;
      this.args.topic.set(
        "mod_topic_private_note_author",
        result.private_note_author || null
      );
    }
    if (result.private_note_created_at !== undefined) {
      this.createdAt = result.private_note_created_at || null;
      this.args.topic.set(
        "mod_topic_private_note_created_at",
        result.private_note_created_at || null
      );
    }
    this.replies = result.replies || [];
    this.args.topic.set("mod_topic_private_note_replies", this.replies);
    this.cookContent();
    this.appEvents.trigger("discourse-mod:messages-updated", this.args.topic);
  }

  @action
  toggleReply() {
    this.replying = !this.replying;
  }

  @action
  updateReplyText(event: Event) {
    this.replyText = (event.target as HTMLTextAreaElement).value;
  }

  @action
  async submitReply() {
    const raw = this.replyText.trim();
    if (!raw) {
      return;
    }
    this.saving = true;

    try {
      const result: NoteThreadResponse = await ajax(
        `/discourse-mod-categories/topic/${this.args.topic.id}/note-reply`,
        { type: "POST", data: { raw } }
      );
      this.replies = result.replies || [];
      this.args.topic.set("mod_topic_private_note_replies", this.replies);
      this.cookContent();
      this.replyText = "";
      this.replying = false;
      this.appEvents.trigger("discourse-mod:messages-updated", this.args.topic);
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  // Per-reply edit / delete

  @action
  startEditReply(reply: DecoratedReply) {
    this.editingReplyId = reply.id;
    this.editText = reply.raw || "";
  }

  @action
  cancelEditReply() {
    this.editingReplyId = null;
    this.editText = "";
  }

  @action
  updateEditText(event: Event) {
    this.editText = (event.target as HTMLTextAreaElement).value;
  }

  @action
  async saveEditReply() {
    const raw = this.editText.trim();
    const replyId = this.editingReplyId;
    if (!raw || !replyId) {
      return;
    }
    this.saving = true;

    try {
      const result: NoteThreadResponse = await ajax(
        `/discourse-mod-categories/topic/${this.args.topic.id}/note-reply`,
        { type: "PUT", data: { reply_id: replyId, raw } }
      );
      this.applyThread(result);
      this.editingReplyId = null;
      this.editText = "";
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  deleteReply(reply: DecoratedReply) {
    this.dialog.confirm({
      message: i18n(
        "discourse_mod_categories.private_note.delete_reply_confirm"
      ),
      didConfirm: async () => {
        this.saving = true;
        try {
          const result: NoteThreadResponse = await ajax(
            `/discourse-mod-categories/topic/${this.args.topic.id}/note-reply`,
            { type: "DELETE", data: { reply_id: reply.id } }
          );
          this.applyThread(result);
        } catch (error) {
          popupAjaxError(error);
        } finally {
          this.saving = false;
        }
      },
    });
  }

  // Note-body edit / delete

  @action
  editNote() {
    this.modal.show(ModTopicMessagesModal, {
      model: { topic: this.args.topic },
    });
  }

  @action
  deleteNote() {
    this.dialog.confirm({
      message: i18n(
        "discourse_mod_categories.private_note.delete_note_confirm"
      ),
      didConfirm: async () => {
        this.saving = true;
        try {
          const result: NoteThreadResponse = await ajax(
            `/discourse-mod-categories/topic/${this.args.topic.id}/note`,
            { type: "DELETE" }
          );
          this.applyThread(result);
        } catch (error) {
          popupAjaxError(error);
        } finally {
          this.saving = false;
        }
      },
    });
  }

  <template>
    <div
      class="mod-private-note-outlet"
      {{didInsert this.refreshOnNavigation}}
      {{didUpdate this.refreshOnNavigation @topic.id}}
    >
      {{#if this.visible}}
        <div
          class="mod-private-note"
          id="mod-private-note"
          {{didInsert this.scrollToNoteIfAnchored}}
        >
          <div class="mod-private-note-marker">
            {{icon "lock"}}
            <span>{{i18n
                "discourse_mod_categories.private_note.heading"
              }}</span>
          </div>

          <article class="mod-private-note-post">
            {{#if this.avatarUrl}}
              <img
                alt=""
                class="mod-private-note-avatar"
                height="45"
                src={{this.avatarUrl}}
                width="45"
              />
            {{/if}}
            <div class="mod-private-note-main">
              <div class="mod-private-note-byline">
                {{#if this.authorName}}
                  <span class="mod-private-note-username">
                    {{this.authorName}}
                  </span>
                {{/if}}
                {{#if this.createdAgo}}
                  <span class="mod-private-note-time">{{this.createdAgo}}</span>
                {{/if}}
                {{#if this.canTouchNote}}
                  <span class="mod-private-note-controls">
                    <DButton
                      class="btn-flat btn-small mod-private-note-edit-note"
                      @action={{this.editNote}}
                      @icon="pencil"
                      @title="discourse_mod_categories.private_note.edit_note"
                    />
                    <DButton
                      class="btn-flat btn-small mod-private-note-delete-note"
                      @action={{this.deleteNote}}
                      @icon="trash-can"
                      @title="discourse_mod_categories.private_note.delete_note"
                    />
                  </span>
                {{/if}}
              </div>
              <div class="cooked">{{this.noteHtml}}</div>
            </div>
          </article>

          {{#each this.decoratedReplies as |reply|}}
            <article
              class="mod-private-note-post mod-private-note-reply"
              id="mod-private-note-reply-{{reply.id}}"
            >
              {{#if reply.avatarUrl}}
                <img
                  alt=""
                  class="mod-private-note-avatar"
                  height="45"
                  src={{reply.avatarUrl}}
                  width="45"
                />
              {{/if}}
              <div class="mod-private-note-main">
                <div class="mod-private-note-byline">
                  {{#if reply.authorName}}
                    <span class="mod-private-note-username">
                      {{reply.authorName}}
                    </span>
                  {{/if}}
                  {{#if reply.agoLabel}}
                    <span
                      class="mod-private-note-time"
                    >{{reply.agoLabel}}</span>
                  {{/if}}
                  {{#if reply.canTouch}}
                    {{#unless reply.editing}}
                      <span class="mod-private-note-controls">
                        <DButton
                          class="btn-flat btn-small mod-private-note-edit-reply"
                          @action={{fn this.startEditReply reply}}
                          @icon="pencil"
                          @title="discourse_mod_categories.private_note.edit_reply"
                        />
                        <DButton
                          class="btn-flat btn-small mod-private-note-delete-reply"
                          @action={{fn this.deleteReply reply}}
                          @icon="trash-can"
                          @title="discourse_mod_categories.private_note.delete_reply"
                        />
                      </span>
                    {{/unless}}
                  {{/if}}
                </div>
                {{#if reply.editing}}
                  <div class="mod-private-note-reply-box">
                    <textarea
                      class="mod-private-note-edit-input"
                      rows="2"
                      value={{this.editText}}
                      {{on "input" this.updateEditText}}
                    ></textarea>
                    <div class="mod-private-note-reply-actions">
                      <DButton
                        class="btn-primary btn-small"
                        @action={{this.saveEditReply}}
                        @disabled={{this.saving}}
                        @label="discourse_mod_categories.private_note.save"
                      />
                      <DButton
                        class="btn-flat btn-small"
                        @action={{this.cancelEditReply}}
                        @label="discourse_mod_categories.private_note.cancel"
                      />
                    </div>
                  </div>
                {{else}}
                  <div
                    class="mod-private-note-reply-text cooked"
                  >{{reply.cooked}}</div>
                {{/if}}
              </div>
            </article>
          {{/each}}

          {{#if this.replying}}
            <div class="mod-private-note-reply-box">
              <textarea
                class="mod-private-note-reply-input"
                placeholder={{i18n
                  "discourse_mod_categories.private_note.reply_placeholder"
                }}
                rows="2"
                value={{this.replyText}}
                {{on "input" this.updateReplyText}}
              ></textarea>
              <div class="mod-private-note-reply-actions">
                <DButton
                  class="btn-primary btn-small"
                  @action={{this.submitReply}}
                  @disabled={{this.saving}}
                  @label="discourse_mod_categories.private_note.add_reply"
                />
                <DButton
                  class="btn-flat btn-small"
                  @action={{this.toggleReply}}
                  @label="discourse_mod_categories.private_note.cancel"
                />
              </div>
            </div>
          {{else}}
            <DButton
              class="btn-flat btn-small mod-private-note-reply-button"
              @action={{this.toggleReply}}
              @icon="reply"
              @label="discourse_mod_categories.private_note.reply"
            />
          {{/if}}

          {{#if this.decoratedViewers.length}}
            <div class="mod-private-note-viewers">
              <button
                aria-expanded={{if this.viewersPopoverOpen "true" "false"}}
                aria-label={{i18n
                  "discourse_mod_categories.private_note.viewed_by"
                  count=this.decoratedViewers.length
                }}
                class="mod-private-note-viewers-pill"
                type="button"
                {{on "click" this.toggleViewersPopover}}
              >
                <span class="mod-private-note-viewers-pill-avatars">
                  {{#each this.pillViewers as |viewer|}}
                    {{#if viewer.avatarUrl}}
                      <img
                        alt={{viewer.name}}
                        class="mod-private-note-viewers-pill-avatar"
                        height="20"
                        src={{viewer.avatarUrl}}
                        title={{viewer.name}}
                        width="20"
                      />
                    {{/if}}
                  {{/each}}
                </span>
                {{#if this.overflowCount}}
                  <span class="mod-private-note-viewers-pill-more">
                    +{{this.overflowCount}}
                  </span>
                {{/if}}
              </button>
              {{#if this.viewersPopoverOpen}}
                <ul class="mod-private-note-viewers-list" role="list">
                  {{#each this.decoratedViewers as |viewer|}}
                    <li class="mod-private-note-viewers-list-item">
                      {{#if viewer.avatarUrl}}
                        <img
                          alt=""
                          class="mod-private-note-viewers-avatar"
                          height="24"
                          src={{viewer.avatarUrl}}
                          width="24"
                        />
                      {{/if}}
                      <span class="mod-private-note-viewers-name">
                        {{viewer.name}}
                      </span>
                      {{#if viewer.agoLabel}}
                        <span class="mod-private-note-viewers-time">
                          {{viewer.agoLabel}}
                        </span>
                      {{/if}}
                    </li>
                  {{/each}}
                </ul>
              {{/if}}
            </div>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}
