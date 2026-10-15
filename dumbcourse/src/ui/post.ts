// A post: header, body, polls, reactions and a compact footer for touch.
// With a D-pad the whole post is one stop; OK opens its action sheet.

import { settings } from "../config.ts";
import {
  processCooked,
  type Picture,
  type PostLink,
} from "../content/cooked.ts";
import { emojiImg } from "../content/emoji.ts";
import { count, dateTime, timeAgo } from "../format.ts";
import { html, raw, type SafeHtml } from "../html.ts";
import { isStaff } from "../session.ts";
import { avatar, userHref } from "../site.ts";
import type { Poll, Post, ReactionCount } from "../types.ts";
import { icon } from "./icons.ts";

export interface RenderedPost {
  html: SafeHtml;
  links: PostLink[];
  images: number;
  pictures: Picture[];
}

export const LIKE = 2;

export function reactionsOn(): boolean {
  return settings.reactions.enabled;
}

export function mainReaction(): string {
  return settings.reactions.main || "heart";
}

export function likeState(p: Post): {
  liked: boolean;
  count: number;
  canLike: boolean;
  canUndo: boolean;
} {
  if (reactionsOn()) {
    const main = mainReaction();
    const used =
      !!p.current_user_used_main_reaction ||
      (!!p.current_user_reaction && p.current_user_reaction.id === main);
    let n = 0;
    const rs = p.reactions || [];
    for (let i = 0; i < rs.length; i++) if (rs[i].id === main) n = rs[i].count;
    return {
      liked: used,
      count: n,
      canLike: !p.yours,
      canUndo: used
        ? !p.current_user_reaction || p.current_user_reaction.can_undo !== false
        : true,
    };
  }
  const a = (p.actions_summary || []).filter((x) => x.id === LIKE)[0];
  return {
    liked: !!(a && a.acted),
    count: (a && a.count) || 0,
    canLike: !!(a && (a.can_act || a.acted)),
    canUndo: !!(a && a.can_undo),
  };
}

// Posts in categories where the forum switched reactions off.
export function reactionsAllowed(
  categoryId: number | null | undefined
): boolean {
  return !categoryId || settings.noReactionCategoryIds.indexOf(categoryId) < 0;
}

function roleBadge(p: Post): SafeHtml {
  if (p.admin)
    return html`<span class="role role-admin" title="Admin"
      >${icon("shield")}<span>Admin</span></span
    >`;
  if (p.moderator)
    return html`<span class="role role-mod" title="Moderator"
      >${icon("wrench")}<span>Mod</span></span
    >`;
  return html``;
}

const ACTION_TEXT: Record<string, string> = {
  "closed.enabled": "closed this topic",
  "closed.disabled": "opened this topic",
  "autoclosed.enabled": "This topic closed automatically",
  "autoclosed.disabled": "This topic opened automatically",
  "archived.enabled": "archived this topic",
  "archived.disabled": "unarchived this topic",
  "pinned.enabled": "pinned this topic",
  "pinned.disabled": "unpinned this topic",
  "pinned_globally.enabled": "pinned this topic globally",
  "pinned_globally.disabled": "unpinned this topic",
  "visible.enabled": "listed this topic",
  "visible.disabled": "unlisted this topic",
  split_topic: "moved posts to a new topic",
  invited_user: "invited someone",
  removed_user: "removed someone",
  user_left: "left this conversation",
  public_topic: "made this topic public",
  private_topic: "made this topic a message",
};

function smallAction(p: Post): SafeHtml {
  const code = p.action_code || "";
  const text = ACTION_TEXT[code] || code.replace(/[._]/g, " ");
  const auto = code.indexOf("auto") === 0;
  return html`<div
    class="post small-action"
    id="post-${p.id}"
    data-key="p${p.post_number}"
    data-n="${p.post_number}"
    tabindex="0"
  >
    ${icon(
      code.indexOf("closed") >= 0
        ? "lock"
        : code.indexOf("pinned") >= 0
          ? "pin"
          : "info"
    )}
    <span
      >${auto ? "" : html`<b>${p.username}</b> `}${text}${p.cooked
        ? html`: ${raw(processCooked(p.cooked).html.value)}`
        : ""} <small>${timeAgo(p.created_at)}</small></span
    >
  </div>`;
}

function whisperNote(p: Post): SafeHtml {
  if (!p.mod_is_whisper) return html``;
  const to: string[] = [];
  (p.mod_whisper_targets || []).forEach(
    (t) => t && t.username && to.push("@" + t.username)
  );
  (p.mod_whisper_target_groups || []).forEach(
    (g) => g && g.name && to.push(g.name)
  );
  (p.mod_whisper_target_badges || []).forEach(
    (b) => b && b.name && to.push(b.name)
  );
  return html`<div class="whisper">
    ${icon("lock")}<span
      >${to.length
        ? "Whisper to " + to.join(", ")
        : p.mod_whisper_admins_only
          ? "Whisper to admins"
          : "Whisper to staff"}</span
    >
  </div>`;
}

export function pollHtml(p: Post, poll: Poll): SafeHtml {
  const votes = (p.polls_votes && p.polls_votes[poll.name]) || [];
  const closed = poll.status === "closed";
  const voted = votes.length > 0;
  const showResults = closed || voted || poll.results === "always";
  const total = poll.voters || 0;
  const multiple = poll.type === "multiple";
  const options = poll.options.map((o) => {
    const mine = votes.indexOf(o.id) >= 0;
    const pct = total ? Math.round(((o.votes || 0) / total) * 100) : 0;
    return html`<li>
      <button
        type="button"
        class="poll-opt${mine ? " mine" : ""}"
        data-act="poll-vote"
        data-post="${p.id}"
        data-poll="${poll.name}"
        data-option="${o.id}"
        ${closed ? raw(" disabled") : ""}
        aria-pressed="${mine ? "true" : "false"}"
      >
        <span class="poll-bar" style="width:${showResults ? pct : 0}%"></span>
        <span class="poll-mark"
          >${mine
            ? icon("check")
            : multiple
              ? raw('<span class="box"></span>')
              : raw('<span class="ring"></span>')}</span
        >
        <span class="poll-text">${raw(o.html)}</span>
        ${showResults ? html`<span class="poll-pct">${pct}%</span>` : ""}
      </button>
    </li>`;
  });
  return html`<div class="poll" data-poll-box="${poll.name}">
    ${poll.title ? html`<div class="poll-title">${raw(poll.title)}</div>` : ""}
    <ul class="poll-list">
      ${options}
    </ul>
    <div class="poll-foot">
      ${icon("poll")} ${count(total)}
      ${total === 1 ? "voter" : "voters"}${closed
        ? " · closed"
        : ""}${multiple && poll.max
        ? ` · pick up to ${poll.max}`
        : ""}${voted && !closed
        ? html` ·
            <button
              type="button"
              class="linkish"
              data-act="poll-remove"
              data-post="${p.id}"
              data-poll="${poll.name}"
            >
              Remove vote
            </button>`
        : ""}
    </div>
  </div>`;
}

function reactionPills(p: Post, allowed: boolean): SafeHtml {
  if (!reactionsOn()) return html``;
  const rs: ReactionCount[] = (p.reactions || []).filter((r) => r.count > 0);
  if (!rs.length) return html``;
  const mine = p.current_user_reaction
    ? p.current_user_reaction.id
    : p.current_user_used_main_reaction
      ? mainReaction()
      : "";
  return html`<div class="reactions">
    ${rs.map(
      (r) =>
        html`<button
          type="button"
          class="rx${r.id === mine ? " mine" : ""}"
          data-act="${allowed ? "react" : "who-reacted"}"
          data-post="${p.id}"
          data-reaction="${r.id}"
          tabindex="-1"
          aria-label="${r.id}, ${r.count}"
        >
          ${emojiImg(r.id, "emoji rx-e")}<span>${r.count}</span>
        </button>`
    )}
  </div>`;
}

export function renderPost(
  p: Post,
  opts: { categoryId?: number | null; topicSlug?: string } = {}
): RenderedPost {
  if (
    p.post_type === 3 ||
    (p.action_code &&
      !String(p.cooked || "")
        .replace(/<[^>]*>/g, "")
        .trim())
  ) {
    return { html: smallAction(p), links: [], images: 0, pictures: [] };
  }
  const hiddenForMe = (p.deleted_at || p.hidden) && !isStaff() && !p.yours;
  if (p.deleted_at && !isStaff()) {
    return {
      html: html`<article
        class="post deleted"
        id="post-${p.id}"
        data-key="p${p.post_number}"
        data-n="${p.post_number}"
        data-post="${p.id}"
        tabindex="0"
      >
        <div class="post-body">
          <p class="muted">${icon("trash")} This post was deleted.</p>
        </div>
      </article>`,
      links: [],
      images: 0,
      pictures: [],
    };
  }
  const body = hiddenForMe
    ? {
        html: html`<p class="muted">This post was hidden by the community.</p>`,
        links: [],
        images: 0,
        pictures: [],
      }
    : processCooked(p.cooked);
  const polls = (p.polls || []).map((poll) => pollHtml(p, poll));
  let bodyHtml = body.html.value;
  // Put each poll where the author wrote it; any left over go at the end.
  const leftover: SafeHtml[] = [];
  for (let i = 0; i < polls.length; i++) {
    const name = (p.polls as Poll[])[i].name;
    const slot = `<div class="poll-slot" data-poll-slot="${name.replace(/"/g, "&quot;")}"></div>`;
    if (bodyHtml.indexOf(slot) >= 0)
      bodyHtml = bodyHtml.replace(slot, polls[i].value);
    else leftover.push(polls[i]);
  }

  const allowed = reactionsAllowed(opts.categoryId);
  const like = likeState(p);
  const name =
    p.name && p.name.toLowerCase() !== p.username.toLowerCase() ? p.name : "";
  const status =
    p.user_status && p.user_status.emoji
      ? emojiImg(p.user_status.emoji, "emoji status")
      : html``;
  const replyTo =
    p.reply_to_post_number && p.reply_to_user
      ? html`<button
          type="button"
          class="reply-to"
          data-act="jump"
          data-n="${p.reply_to_post_number}"
          tabindex="-1"
        >
          ${icon("reply")}<span>@${p.reply_to_user.username}</span>
        </button>`
      : html``;
  const likeBtn =
    allowed && (like.canLike || like.count)
      ? html`<button
          type="button"
          class="pa like${like.liked ? " on" : ""}"
          data-act="like"
          data-post="${p.id}"
          tabindex="-1"
          aria-label="${like.liked ? "Unlike" : "Like"}${like.count
            ? `, ${like.count}`
            : ""}"
          aria-pressed="${like.liked ? "true" : "false"}"
        >
          ${icon(like.liked ? "heartOn" : "heart")}${like.count
            ? html`<span>${like.count}</span>`
            : ""}
        </button>`
      : html``;
  const label = `Post ${p.post_number} by ${p.username}, ${timeAgo(p.created_at)} ago${like.count ? `, ${like.count} likes` : ""}${p.bookmarked ? ", bookmarked" : ""}`;

  const markup = html`<article
    class="post${p.deleted_at ? " deleted" : ""}${p.hidden
      ? " is-hidden"
      : ""}${p.yours ? " mine" : ""}${p.mod_is_whisper ? " whispered" : ""}"
    id="post-${p.id}"
    data-key="p${p.post_number}"
    data-n="${p.post_number}"
    data-post="${p.id}"
    tabindex="0"
    data-enter="post-menu"
    aria-label="${label}"
  >
    <header class="post-head">
      <a
        class="post-avatar"
        href="${userHref(p.username)}"
        tabindex="-1"
        aria-hidden="true"
        >${avatar(p.avatar_template, 32)}</a
      >
      <div class="post-who">
        <div class="post-name">
          <a href="${userHref(p.username)}" tabindex="-1"
            >${name || p.username}</a
          >${status}${roleBadge(p)}
        </div>
        <div class="post-sub">
          ${name ? html`<span>@${p.username}</span>` : ""}${p.user_title
            ? html`<span>${p.user_title}</span>`
            : ""}
        </div>
      </div>
      <div class="post-when" title="${dateTime(p.created_at)}">
        ${timeAgo(p.created_at)}<small>#${p.post_number}</small>
      </div>
    </header>
    ${p.deleted_at
      ? html`<div class="notice error small">
          ${icon("trash")} Deleted — only staff can see this.
        </div>`
      : ""}
    ${whisperNote(p)} ${replyTo}
    <div class="post-body cooked">${raw(bodyHtml)}${leftover}</div>
    ${reactionPills(p, allowed)}
    <footer class="post-foot">
      ${likeBtn}
      ${p.reply_count
        ? html`<button
            type="button"
            class="pa"
            data-act="replies"
            data-post="${p.id}"
            tabindex="-1"
          >
            ${icon("chat")}<span>${p.reply_count}</span>
          </button>`
        : ""}
      ${p.bookmarked
        ? html`<span class="pa on" aria-label="Bookmarked"
            >${icon("bookmarkOn")}</span
          >`
        : ""}
      <span class="spacer"></span>
      <button
        type="button"
        class="pa"
        data-act="reply-post"
        data-post="${p.id}"
        tabindex="-1"
        aria-label="Reply"
      >
        ${icon("reply")}<span class="pa-l">Reply</span>
      </button>
      <button
        type="button"
        class="pa"
        data-act="post-menu"
        data-post="${p.id}"
        tabindex="-1"
        aria-label="More actions"
      >
        ${icon("more")}
      </button>
    </footer>
  </article>`;
  return {
    html: markup,
    links: body.links,
    images: body.images,
    pictures: body.pictures,
  };
}
