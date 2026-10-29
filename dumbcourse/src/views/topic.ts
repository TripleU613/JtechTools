// A topic. Up/Down read (a long post scrolls before focus moves on),
// Left/Right jump from post to post, OK opens the post's actions, and the
// keypad has shortcuts: 3 reply, 5 like, 9 jump to a post number.

import { del, errorMessage, get, post as apiPost, put } from "../api.ts";
import { go } from "../app.ts";
import { invalidate, peek, store } from "../cache.ts";
import { closest, removeNode } from "../compat.ts";
import { settings } from "../config.ts";
import { emojify } from "../content/emoji.ts";
import {
  cookedToText,
  type Picture,
  type PostLink,
} from "../content/cooked.ts";
import {
  $,
  $$,
  appendHtml,
  byId,
  copyText,
  fromHtml,
  nearBottom,
  prependHtml,
  toggleClass,
} from "../dom.ts";
import { count, plural, truncate } from "../format.ts";
import { html, type SafeHtml } from "../html.ts";
import { subscribe } from "../messagebus.ts";
import { focus, focusByKey } from "../nav.ts";
import { prefs } from "../prefs.ts";
import { href, type RouteContext } from "../router.ts";
import type { Screen } from "../screen.ts";
import { isStaff, user } from "../session.ts";
import { category, categoryBadge, topicPath, userPath } from "../site.ts";
import type { Post, Topic } from "../types.ts";
import type { Whisper } from "./composer.ts";
import { hiddenParts, hiddenState, showHidden } from "../ui/hidden-text.ts";
import { showPictures, viewPicture } from "../ui/pictures.ts";
import { icon } from "../ui/icons.ts";
import {
  actionSheet,
  confirmDialog,
  promptDialog,
  toast,
  type SheetItem,
} from "../ui/layers.ts";
import {
  likeState,
  mainReaction,
  reactionRow,
  reactionsAllowed,
  reactionsOn,
  renderPost,
  LIKE,
} from "../ui/post.ts";
import { decodeEntities, topicRow, usersById } from "../ui/topic-row.ts";
import { useScreen } from "./common.ts";
import { openComposer } from "./composer.ts";
import { levelLabel, topicLevelSheet } from "./levels.ts";
import { topicModToolItems } from "./topic-mod-tools.ts";
import { topicStaffItems } from "./topic-staff.ts";
import { canSeeHistory, editHistory, postStaffItems } from "./post-staff.ts";
import {
  canSelectPosts,
  type Selection,
  selectionMenu,
  toggleSelected,
} from "./select-posts.ts";
import { chooseCategory, fail, isStaffUser } from "./staff-common.ts";
import { chooseWhisperAudience } from "./whisper-audience.ts";
import { reactionPicker, whoReacted } from "./reactions.ts";

interface State {
  topic: Topic;
  posts: Record<number, Post>; // by post id
  links: Record<number, PostLink[]>;
  images: Record<number, number>;
  pictures: Record<number, Picture[]>;
  stream: number[];
  loadedFrom: number; // index into stream
  loadedTo: number; // exclusive
  level: number;
  // Called after posts are drawn or redrawn (the selection marks them).
  onPosts?: () => void;
}

const BATCH = 20;

function postKeyNumber(el: HTMLElement | null): number {
  return el ? parseInt(el.getAttribute("data-n") || "0", 10) : 0;
}

function focusedPost(): HTMLElement | null {
  const el = closest(document.activeElement, ".post");
  return el;
}

export function topicRoute(ctx: RouteContext): Promise<void> {
  // /t/:slug/:id(/:n) or /t/:id(/:n)
  const parts = (ctx.params.rest || "").split("/").filter(Boolean);
  let id = 0;
  let n = 0;
  if (parts.length >= 2 && /^\d+$/.test(parts[1])) {
    id = parseInt(parts[1], 10);
    n = parts[2] && /^\d+$/.test(parts[2]) ? parseInt(parts[2], 10) : 0;
  } else if (parts.length >= 1 && /^\d+$/.test(parts[0])) {
    id = parseInt(parts[0], 10);
    n = parts[1] && /^\d+$/.test(parts[1]) ? parseInt(parts[1], 10) : 0;
  }
  if (ctx.query.n && /^\d+$/.test(ctx.query.n)) n = parseInt(ctx.query.n, 10);
  return renderTopic(ctx, id, n);
}

function renderTopic(
  ctx: RouteContext,
  id: number,
  target: number
): Promise<void> {
  const s = useScreen();
  s.title("Topic", { back: true });
  if (!id) {
    s.error("That topic link looks broken.");
    return Promise.resolve();
  }
  const cacheKey = `/t/${id}.json`;
  const cached = !target ? peek<Topic>(cacheKey, 10 * 60 * 1000) : null;
  if (cached) paintTopic(s, ctx, cached, target, true);
  else s.loading();
  const path = target ? `/t/${id}/${target}.json` : `/t/${id}.json`;
  return get<Topic>(path + (isStaff() ? "?show_deleted=true" : "")).then(
    (t) => {
      if (!s.alive()) return;
      store(cacheKey, t);
      paintTopic(s, ctx, t, target, false);
    },
    (e: unknown) => {
      if (!s.alive()) return;
      if (!cached)
        s.error(errorMessage(e), () =>
          go(ctx.path + location.search, { replace: true })
        );
      else toast(errorMessage(e), "error");
    }
  );
}

function paintTopic(
  s: Screen,
  ctx: RouteContext,
  t: Topic,
  target: number,
  stale: boolean
): void {
  const state: State = {
    topic: t,
    posts: {},
    links: {},
    images: {},
    pictures: {},
    stream: t.post_stream.stream || [],
    loadedFrom: 0,
    loadedTo: 0,
    level:
      t.details && typeof t.details.notification_level === "number"
        ? t.details.notification_level
        : 1,
  };
  const isPm = t.archetype === "private_message";
  const title = decodeEntities(t.fancy_title || t.title);
  s.title(title, {
    back: true,
    sub: isPm
      ? "Message"
      : category(t.category_id)
        ? (category(t.category_id) as { name: string }).name
        : "",
  });

  const posts = t.post_stream.posts || [];
  const ids = posts.map((p) => p.id);
  const first = state.stream.indexOf(ids[0]);
  state.loadedFrom = first < 0 ? 0 : first;
  state.loadedTo = state.loadedFrom + posts.length;

  const tags =
    settings.tagsEnabled && t.tags && t.tags.length
      ? html`<div class="topic-tags">
          ${t.tags.map((tag) => {
            const name = typeof tag === "string" ? tag : tag.name;
            return html`<a
              class="tag"
              href="${href("/tag/" + encodeURIComponent(name))}"
              tabindex="-1"
              >${name}</a
            >`;
          })}
        </div>`
      : html``;

  const header = html`<header
    class="topic-head"
    data-key="head"
    tabindex="0"
    data-enter="topic-menu"
  >
    <h1 class="topic-title">
      ${t.closed ? icon("lock", "st") : ""}${t.archived
        ? icon("archive", "st")
        : ""}${t.pinned ? icon("pin", "st") : ""}${emojify(title)}
    </h1>
    <div class="topic-meta">
      ${categoryBadge(t.category_id)}${tags}<span>${plural(
        Math.max(0, t.posts_count - 1),
        "reply",
        "replies"
      )}</span>${t.views
        ? html`<span>${count(t.views)} views</span>`
        : ""}${t.like_count
        ? html`<span>${count(t.like_count)} likes</span>`
        : ""}${state.level !== 1
        ? html`<span class="lvl">${levelLabel(state.level)}</span>`
        : ""}
    </div>
  </header>`;

  s.render(
    html`${header}
      <div id="loadEarlier" class="load-edge"></div>
      <div id="posts" class="posts" role="feed" aria-label="Posts"></div>
      <div id="loadLater" class="load-edge"></div>
      <div id="typing" class="typing" aria-live="polite" hidden></div>
      <div class="topic-end">
        ${t.details && t.details.can_create_post !== false
          ? html`<button
              type="button"
              class="btn primary block"
              data-act="reply-topic"
              data-key="reply"
            >
              ${icon("reply")}Reply
            </button>`
          : t.closed
            ? html`<p class="notice">${icon("lock")} Closed</p>`
            : ""}
        <div id="suggested"></div>
      </div>`
  );

  const container = byId("posts") as HTMLElement;
  appendPosts(state, container, posts, "end");
  updateEdges(state);
  suggested(t);

  if (!stale || !ctx.restore) {
    if (target) {
      requestAnimationFrame(() => {
        if (!focusByKey("p" + nearestLoaded(state, target))) focusByKey("head");
      });
    } else if (!ctx.restore) {
      requestAnimationFrame(() => {
        // Opening a topic you've read before: continue where you left off.
        const last = t.last_read_post_number || 0;
        if (
          last > 1 &&
          last < t.highest_post_number &&
          focusByKey("p" + (last + 1))
        )
          return;
        focusByKey("head");
      });
    }
  }
  if (stale) return;

  wireTopic(s, ctx, state, container);
}

function nearestLoaded(state: State, n: number): number {
  let best = 0;
  for (const id in state.posts) {
    if (!state.posts.hasOwnProperty(id)) continue;
    const pn = state.posts[id].post_number;
    if (pn <= n && pn > best) best = pn;
  }
  return best || n;
}

function appendPosts(
  state: State,
  container: HTMLElement,
  posts: Post[],
  where: "start" | "end"
): void {
  const t = state.topic;
  const parts: SafeHtml[] = [];
  for (let i = 0; i < posts.length; i++) {
    const p = posts[i];
    if (state.posts[p.id] && byId("post-" + p.id)) continue;
    state.posts[p.id] = p;
    const r = renderPost(p, { categoryId: t.category_id, topicSlug: t.slug });
    state.links[p.id] = r.links;
    state.images[p.id] = r.images;
    state.pictures[p.id] = r.pictures;
    parts.push(r.html);
  }
  if (!parts.length) return;
  if (where === "end") appendHtml(container, html`${parts}`);
  else prependHtml(container, html`${parts}`);
  if (state.onPosts) state.onPosts();
}

function replacePost(state: State, p: Post): void {
  const old = byId("post-" + p.id);
  state.posts[p.id] = p;
  const r = renderPost(p, {
    categoryId: state.topic.category_id,
    topicSlug: state.topic.slug,
  });
  state.links[p.id] = r.links;
  state.images[p.id] = r.images;
  state.pictures[p.id] = r.pictures;
  const fresh = fromHtml(r.html);
  if (!old || !old.parentNode || !fresh) return;
  const hadFocus = old.contains(document.activeElement);
  old.parentNode.replaceChild(fresh, old);
  if (hadFocus) focus(fresh, false);
  if (state.onPosts) state.onPosts();
}

function updateEdges(state: State): void {
  const earlier = byId("loadEarlier");
  const later = byId("loadLater");
  const before = state.loadedFrom;
  const after = state.stream.length - state.loadedTo;
  if (earlier) {
    earlier.innerHTML =
      before > 0
        ? html`<button
            type="button"
            class="btn block ghost"
            data-act="load-earlier"
            data-key="earlier"
          >
            ${icon("arrowUp")}${plural(before, "earlier post")}
          </button>`.value
        : "";
  }
  if (later) {
    later.innerHTML =
      after > 0
        ? html`<button
            type="button"
            class="btn block"
            data-act="load-later"
            data-key="later"
          >
            ${icon("arrowDown")}${plural(after, "more post")}
          </button>`.value
        : "";
  }
}

function suggested(t: Topic): void {
  const box = byId("suggested");
  if (!box || !t.suggested_topics || !t.suggested_topics.length) return;
  const rows = t.suggested_topics
    .slice(0, 5)
    .map((x) => topicRow(x, usersById([]), { excerpt: false }));
  box.innerHTML = html`<h2 class="section-title">More topics</h2>
    <ul class="rows">
      ${rows}
    </ul>`.value;
}

function fetchPosts(topicId: number, ids: number[]): Promise<Post[]> {
  const q = ids.map((x) => "post_ids[]=" + x).join("&");
  return get<{ post_stream?: { posts: Post[] } }>(
    `/t/${topicId}/posts.json?${q}${isStaff() ? "&show_deleted=true" : ""}`
  ).then((d) =>
    ((d.post_stream && d.post_stream.posts) || []).sort(
      (a, b) => a.post_number - b.post_number
    )
  );
}

function wireTopic(
  s: Screen,
  ctx: RouteContext,
  state: State,
  container: HTMLElement
): void {
  const t = state.topic;
  let busy = false;

  const loadLater = (): Promise<void> => {
    if (busy || state.loadedTo >= state.stream.length) return Promise.resolve();
    busy = true;
    const ids = state.stream.slice(state.loadedTo, state.loadedTo + BATCH);
    const btn = $("[data-act=load-later]");
    if (btn) btn.setAttribute("disabled", "");
    return fetchPosts(t.id, ids).then(
      (posts) => {
        busy = false;
        if (!s.alive()) return;
        appendPosts(state, container, posts, "end");
        state.loadedTo += ids.length;
        updateEdges(state);
      },
      (e: unknown) => {
        busy = false;
        if (btn) btn.removeAttribute("disabled");
        toast(errorMessage(e), "error");
      }
    );
  };

  const loadEarlier = (): Promise<void> => {
    if (busy || state.loadedFrom <= 0) return Promise.resolve();
    busy = true;
    const from = Math.max(0, state.loadedFrom - BATCH);
    const ids = state.stream.slice(from, state.loadedFrom);
    return fetchPosts(t.id, ids).then(
      (posts) => {
        busy = false;
        if (!s.alive()) return;
        const firstEl = container.firstElementChild as HTMLElement | null;
        const before = firstEl ? firstEl.getBoundingClientRect().top : 0;
        appendPosts(state, container, posts, "start");
        state.loadedFrom = from;
        updateEdges(state);
        // Keep what you were reading where it was.
        if (firstEl)
          window.scrollBy(0, firstEl.getBoundingClientRect().top - before);
        const last = posts[posts.length - 1];
        if (last) focusByKey("p" + last.post_number);
      },
      (e: unknown) => {
        busy = false;
        toast(errorMessage(e), "error");
      }
    );
  };

  // Jump to a post number, loading around it if needed.
  const jumpTo = (n: number): void => {
    if (n < 1) n = 1;
    if (n > t.highest_post_number) n = t.highest_post_number;
    if (focusByKey("p" + n)) return;
    go(topicPath(t.id, t.slug, n), { replace: true });
  };

  s.act("load-later", () => void loadLater());
  s.act("load-earlier", () => void loadEarlier());
  s.act("jump", (el) => jumpTo(parseInt(el.getAttribute("data-n") || "1", 10)));
  container.addEventListener("dc:end", () => void loadLater());
  const onScroll = () => {
    if (nearBottom(600)) void loadLater();
  };
  window.addEventListener("scroll", onScroll);
  s.onLeave(() => window.removeEventListener("scroll", onScroll));

  const postFrom = (el: HTMLElement): Post | null => {
    const idAttr =
      el.getAttribute("data-post") ||
      (closest(el, ".post") || el).getAttribute("data-post");
    return idAttr ? state.posts[parseInt(idAttr, 10)] || null : null;
  };

  const refreshPost = (postId: number): Promise<void> =>
    get<Post>(`/posts/${postId}.json`).then(
      (p) => {
        if (s.alive() && p && p.id) replacePost(state, p);
      },
      () => undefined
    );

  const reloadTopic = (message: string) => {
    toast(message, "success");
    invalidate(`/t/${t.id}`);
    invalidate("/latest");
    go(ctx.path + location.search, { replace: true });
  };

  // ── Composer hooks ──────────────────────────────────────────────────

  const reply = (p: Post | null, quote?: string, whisper?: Whisper) => {
    openComposer({
      whisper,
      kind: "reply",
      topicId: t.id,
      topicTitle: decodeEntities(t.fancy_title || t.title),
      categoryId: t.category_id || null,
      replyTo: p ? { postNumber: p.post_number, username: p.username } : null,
      quote: quote || "",
      participants: participants(state),
      onPosted: (created: Post) => {
        if (!s.alive()) return;
        state.stream.push(created.id);
        if (state.loadedTo === state.stream.length - 1) {
          appendPosts(state, container, [created], "end");
          state.loadedTo = state.stream.length;
        }
        updateEdges(state);
        invalidate(`/t/${t.id}`);
        requestAnimationFrame(() => focusByKey("p" + created.post_number));
      },
    });
  };

  const quote = (p: Post) => {
    get<{ raw?: string }>(`/posts/${p.id}.json`).then(
      (d) => {
        const text = (d && d.raw) || cookedToText(p.cooked);
        reply(
          p,
          `[quote="${p.username}, post:${p.post_number}, topic:${t.id}"]\n${text.replace(/\n{3,}/g, "\n\n")}\n[/quote]\n\n`
        );
      },
      () =>
        reply(
          p,
          `[quote="${p.username}, post:${p.post_number}, topic:${t.id}"]\n${cookedToText(p.cooked)}\n[/quote]\n\n`
        )
    );
  };

  const edit = (p: { id: number; post_number?: number }) => {
    get<{ raw?: string; post_number?: number }>(`/posts/${p.id}.json`).then(
      (d) => {
        const n = p.post_number || (d && d.post_number) || 0;
        openComposer({
          kind: "edit",
          topicId: t.id,
          topicTitle: decodeEntities(t.fancy_title || t.title),
          postId: p.id,
          postNumber: n,
          raw: (d && d.raw) || "",
          categoryId: t.category_id || null,
          editTitle:
            n === 1 && !!(t.details && t.details.can_edit)
              ? decodeEntities(t.title)
              : null,
          onSaved: () => {
            void refreshPost(p.id);
            if (n === 1) invalidate(`/t/${t.id}`);
          },
        });
      },
      (e: unknown) => toast(errorMessage(e), "error")
    );
  };

  // Staff replies only staff (or the people named) can read: core's
  // whispers, or this plugin's whispers to someone.
  const whisperItems = (p: Post | null): SheetItem[] => {
    const out: SheetItem[] = [];
    if (!isStaffUser() || t.archetype === "private_message") return out;
    const plugin = !!(settings.staff && settings.staff.whisperTargeted);
    if ((user && user.whisperer) || plugin)
      out.push({
        label: p ? "Whisper reply (staff only)" : "Whisper (staff only)",
        icon: "lock",
        run: () =>
          reply(p, undefined, {
            core: !!(user && user.whisperer),
            userIds: [],
            label: "staff",
          }),
      });
    if (
      p &&
      plugin &&
      p.user_id > 0 &&
      !p.staff &&
      !p.admin &&
      !p.moderator &&
      !(user && p.username === user.username)
    )
      out.push({
        label: `Whisper to @${p.username}`,
        icon: "lock",
        run: () =>
          reply(p, undefined, {
            core: false,
            userIds: [p.user_id],
            label: "@" + p.username + " and staff",
          }),
      });
    if (plugin)
      out.push({
        label: "Whisper to…",
        icon: "lock",
        run: () => chooseWhisperAudience((w) => reply(p, undefined, w)),
      });
    return out;
  };

  s.act("reply-topic", () => reply(null));
  // Arriving from Drafts: reopen the saved reply or edit.
  if (ctx.query.compose === "1") requestAnimationFrame(() => reply(null));
  const editId = parseInt(ctx.query.edit || "", 10);
  if (editId > 0) requestAnimationFrame(() => edit({ id: editId }));
  s.act("reply-post", (el) => reply(postFrom(el)));

  // ── Likes & reactions ───────────────────────────────────────────────

  const toggleLike = (p: Post) => {
    if (!reactionsAllowed(t.category_id)) {
      toast("Reactions are switched off in this category.");
      return;
    }
    const like = likeState(p);
    if (!like.liked && !like.canLike) {
      toast(
        p.yours ? "You can't like your own post." : "You can't like this post."
      );
      return;
    }
    if (like.liked && !like.canUndo) {
      toast("It's too late to undo that like.");
      return;
    }
    let req: Promise<unknown>;
    if (reactionsOn()) {
      req = put(
        `/discourse-reactions/posts/${p.id}/custom-reactions/${encodeURIComponent(mainReaction())}/toggle.json`
      );
    } else if (like.liked) {
      req = del(`/post_actions/${p.id}.json?post_action_type_id=${LIKE}`);
    } else {
      req = apiPost("/post_actions.json", {
        id: p.id,
        post_action_type_id: LIKE,
        flag_topic: false,
      });
    }
    req.then(
      (res) => {
        const updated =
          res && typeof res === "object" && (res as Post).id === p.id
            ? (res as Post)
            : null;
        if (updated && updated.cooked) replacePost(state, updated);
        else void refreshPost(p.id);
        toast(like.liked ? "Like removed." : "Liked.", "success");
      },
      (e: unknown) => toast(errorMessage(e), "error")
    );
  };

  const react = (p: Post, reaction: string) => {
    put(
      `/discourse-reactions/posts/${p.id}/custom-reactions/${encodeURIComponent(reaction)}/toggle.json`
    ).then(
      (res) => {
        const updated =
          res && typeof res === "object" && (res as Post).id === p.id
            ? (res as Post)
            : null;
        if (updated && updated.cooked) replacePost(state, updated);
        else void refreshPost(p.id);
      },
      (e: unknown) => toast(errorMessage(e), "error")
    );
  };

  s.act("like", (el) => {
    const p = postFrom(el);
    if (p) toggleLike(p);
  });
  s.act("react", (el) => {
    const p = postFrom(el);
    const r = el.getAttribute("data-reaction") || "";
    if (!p || !r) return;
    if (p.yours) whoReacted(p.id, r);
    else react(p, r);
  });
  // The footer's react button rolls the reactions out beside it, and shuts
  // them again; one post's row at a time.
  s.act("react-row", (el) => {
    const p = postFrom(el);
    const foot = closest(el, ".post-foot");
    if (!p || !foot) return;
    const wasOpen = !!$(".rx-row", foot);
    $$(".post-foot.rolled").forEach((f) => {
      const row = $(".rx-row", f);
      if (row) removeNode(row);
      f.classList.remove("rolled");
      const opener = $(".rx-open", f);
      if (opener) opener.setAttribute("aria-expanded", "false");
    });
    if (wasOpen) return;
    const row = fromHtml(reactionRow(p));
    if (!row) return;
    foot.insertBefore(row, el.nextSibling);
    foot.classList.add("rolled");
    el.setAttribute("aria-expanded", "true");
  });
  s.act("who-reacted", (el) => {
    const p = postFrom(el);
    if (p) whoReacted(p.id, el.getAttribute("data-reaction") || "");
  });

  // ── Bookmarks, flags, delete ─────────────────────────────────────────

  const toggleBookmark = (p: Post) => {
    const req: Promise<unknown> =
      p.bookmarked && p.bookmark_id
        ? del(`/bookmarks/${p.bookmark_id}.json`)
        : apiPost("/bookmarks.json", {
            bookmarkable_id: p.id,
            bookmarkable_type: "Post",
          });
    req.then(
      () => {
        toast(p.bookmarked ? "Bookmark removed." : "Bookmarked.", "success");
        invalidate("/u/" + (user ? user.username : "") + "/bookmarks");
        void refreshPost(p.id);
      },
      (e: unknown) => toast(errorMessage(e), "error")
    );
  };

  const flag = (p: Post) => {
    const types = settings.flagTypes.filter((f) => f.name && f.id !== LIKE);
    if (!types.length) {
      toast("Flagging isn't available.");
      return;
    }
    actionSheet(
      "Flag this post",
      types.map((f) => ({
        label: f.name,
        // Plain text only (escaped by html``): descriptions can hold links.
        hint: f.description
          ? truncate(decodeEntities(f.description.replace(/<[^>]*>/g, "")), 60)
          : "",
        run: () => {
          const send = (message?: string) =>
            apiPost("/post_actions.json", {
              id: p.id,
              post_action_type_id: f.id,
              flag_topic: false,
              message: message || undefined,
            }).then(
              () => toast("Flagged.", "success"),
              (e: unknown) => toast(errorMessage(e), "error")
            );
          if (f.require_message || f.is_custom_flag) {
            promptDialog("What's wrong with this post?", {
              title: f.name,
              multiline: true,
              ok: "Send flag",
            }).then((msg) => {
              if (msg && msg.replace(/\s+/g, "")) void send(msg);
            });
          } else {
            void send();
          }
        },
      })),
      { subtitle: `Post #${p.post_number} by @${p.username}` }
    );
  };

  const removePost = (p: Post) => {
    confirmDialog(
      p.post_number === 1
        ? "Delete this post? The first post deletes the whole topic."
        : "Delete this post?",
      { ok: "Delete", danger: true }
    ).then((ok) => {
      if (!ok) return;
      del(`/posts/${p.id}.json`).then(
        () => {
          toast("Deleted.", "success");
          invalidate(`/t/${t.id}`);
          if (p.post_number === 1 && !isStaff()) go("/", { replace: true });
          else void refreshPost(p.id);
        },
        (e: unknown) => toast(errorMessage(e), "error")
      );
    });
  };

  const recoverPost = (p: Post) => {
    put(`/posts/${p.id}/recover.json`).then(
      () => {
        toast("Restored.", "success");
        void refreshPost(p.id);
      },
      (e: unknown) => toast(errorMessage(e), "error")
    );
  };

  // ── Polls ────────────────────────────────────────────────────────────

  s.act("poll-vote", (el) => {
    const p = postFrom(el);
    const pollName = el.getAttribute("data-poll") || "";
    const option = el.getAttribute("data-option") || "";
    if (!p) return;
    const poll = (p.polls || []).filter((x) => x.name === pollName)[0];
    if (!poll) return;
    let votes = ((p.polls_votes && p.polls_votes[pollName]) || []).slice();
    if (poll.type === "multiple") {
      const i = votes.indexOf(option);
      if (i >= 0) votes.splice(i, 1);
      else votes.push(option);
      if (poll.max && votes.length > poll.max) {
        toast(`Pick up to ${poll.max}.`);
        return;
      }
      if (!votes.length) return;
    } else {
      votes = [option];
    }
    put("/polls/vote.json", {
      post_id: p.id,
      poll_name: pollName,
      options: votes,
    }).then(
      (res) => {
        const r = res as { poll?: typeof poll; vote?: string[] };
        if (r && r.poll) {
          p.polls = (p.polls || []).map((x) =>
            x.name === pollName ? (r.poll as typeof poll) : x
          );
          p.polls_votes = p.polls_votes || {};
          p.polls_votes[pollName] = r.vote || votes;
          replacePost(state, p);
          focusByKey("p" + p.post_number);
        } else {
          void refreshPost(p.id);
        }
        toast("Vote saved.", "success");
      },
      (e: unknown) => toast(errorMessage(e), "error")
    );
  });
  s.act("poll-remove", (el) => {
    const p = postFrom(el);
    const pollName = el.getAttribute("data-poll") || "";
    if (!p) return;
    del("/polls/vote.json", { post_id: p.id, poll_name: pollName }).then(
      () => void refreshPost(p.id),
      (e: unknown) => toast(errorMessage(e), "error")
    );
  });

  // ── The post's action sheet ─────────────────────────────────────────

  const postMenu = (p: Post) => {
    const items: SheetItem[] = [];
    const like = likeState(p);
    const allowed = reactionsAllowed(t.category_id);
    const canReply = !(t.details && t.details.can_create_post === false);
    if (allowed && (like.canLike || like.liked)) {
      items.push({
        label: like.liked ? "Unlike" : "Like",
        icon: like.liked ? "heartOn" : "heart",
        hint: "5",
        run: () => toggleLike(p),
      });
    }
    if (
      allowed &&
      reactionsOn() &&
      !p.yours &&
      settings.reactions.list.length > 1
    ) {
      items.push({
        label: "React…",
        icon: "smile",
        run: () => reactionPicker(p, (r) => react(p, r)),
      });
    }
    if (canReply) {
      items.push({
        label: "Reply",
        icon: "reply",
        hint: "3",
        run: () => reply(p),
      });
      items.push({ label: "Quote", icon: "quote", run: () => quote(p) });
    }
    items.push({
      label: p.bookmarked ? "Remove bookmark" : "Bookmark",
      icon: p.bookmarked ? "bookmarkOn" : "bookmark",
      run: () => toggleBookmark(p),
    });
    const liked = like.count > 0 || (p.reactions || []).length > 0;
    if (liked)
      items.push({
        label: reactionsOn() ? "Who reacted" : "Who liked",
        icon: "users",
        run: () => whoReacted(p.id, ""),
      });

    const links = state.links[p.id] || [];
    const postEl = byId("post-" + p.id);
    const hidden = postEl ? hiddenParts(postEl) : null;
    const hiddenNow = hidden ? hiddenState(hidden) : null;
    if (hidden && hiddenNow)
      items.push({
        label: hiddenNow === "hidden" ? "Show hidden text" : "Hide hidden text",
        icon: hiddenNow === "hidden" ? "eye" : "eyeOff",
        run: () => showHidden(hidden, hiddenNow === "hidden"),
      });
    // First in the menu: it's what a post with pictures is opened for.
    const pictures = state.pictures[p.id] || [];
    if (pictures.length)
      items.unshift({
        label:
          pictures.length === 1
            ? "View picture"
            : `View pictures (${pictures.length})`,
        icon: "image",
        run: () => showPictures(pictures),
      });
    if (state.images[p.id] && prefs.images !== "show") {
      items.push({
        label: plural(state.images[p.id], "Show image", "Show images"),
        icon: "image",
        run: () => {
          $$(".img-placeholder", byId("post-" + p.id) || document.body).forEach(
            (b) => loadImage(b)
          );
        },
      });
    }
    if (p.reply_to_post_number)
      items.push({
        label: `In reply to #${p.reply_to_post_number}`,
        icon: "jump",
        run: () => jumpTo(p.reply_to_post_number as number),
      });
    if (p.reply_count)
      items.push({
        label: plural(p.reply_count, "reply", "replies") + " to this post",
        icon: "chat",
        run: () => showReplies(p),
      });
    items.push({
      label: `@${p.username}'s profile`,
      icon: "user",
      href: href(userPath(p.username)),
    });
    items.push({
      label: "Copy link",
      icon: "link",
      run: () => {
        const url =
          location.protocol +
          "//" +
          location.host +
          settings.subfolder +
          "/t/" +
          t.slug +
          "/" +
          t.id +
          "/" +
          p.post_number;
        if (copyText(url)) toast("Link copied.", "success");
        else void promptDialog("Link to this post", { value: url, ok: "Done" });
      },
    });
    if (p.can_edit)
      items.push({ label: "Edit", icon: "edit", run: () => edit(p) });
    if (p.deleted_at && p.can_recover)
      items.push({ label: "Restore", icon: "undo", run: () => recoverPost(p) });
    else if (p.can_delete)
      items.push({
        label: "Delete",
        icon: "trash",
        danger: true,
        run: () => removePost(p),
      });
    if (!p.yours)
      items.push({
        label: "Flag…",
        icon: "flag",
        danger: true,
        run: () => flag(p),
      });
    if (canSeeHistory(p))
      items.push({
        label: "Edit history",
        icon: "clock",
        run: () =>
          editHistory(p, () => {
            invalidate(`/t/${t.id}`);
            void refreshPost(p.id);
          }),
      });
    if (canReply) whisperItems(p).forEach((w) => items.push(w));

    const staff = postStaffItems(p, t, {
      refresh: (postId, message) => {
        toast(message, "success");
        invalidate(`/t/${t.id}`);
        void refreshPost(postId);
      },
      reload: reloadTopic,
    });
    if (staff.length) {
      items.push({ label: "Moderation", heading: true });
      staff.forEach((x) => items.push(x));
    }

    if (links.length) {
      items.push({
        label: plural(links.length, "link") + " in this post",
        heading: true,
      });
      for (let i = 0; i < links.length && i < 25; i++) {
        const l = links[i];
        items.push({
          label: l.text,
          icon: l.internal ? "link" : "external",
          href: l.href,
          external: !l.internal,
          hint: l.internal ? "" : hostOf(l.href),
        });
      }
    }
    actionSheet(html`#${p.post_number} · ${p.username}`, items, {
      subtitle: excerptOf(p),
    });
  };

  s.act("post-menu", (el) => {
    const p = postFrom(el);
    if (!p) return;
    if (selecting) {
      toggleSelected(selection(), p.id);
      return;
    }
    postMenu(p);
  });

  const showReplies = (p: Post) => {
    get<Post[]>(`/posts/${p.id}/replies.json`).then(
      (list) => {
        const items: SheetItem[] = (list || []).map((r) => ({
          label: html`@${r.username}: ${excerptOf(r)}`,
          icon: "reply",
          run: () => jumpTo(r.post_number),
        }));
        if (!items.length) toast("No replies found.");
        else actionSheet(`Replies to #${p.post_number}`, items);
      },
      (e: unknown) => toast(errorMessage(e), "error")
    );
  };

  // Tap-to-load images.
  s.act("load-image", (el) => loadImage(el));

  // Tapping a picture in a post opens the viewer on it, not the bare file.
  // A picture this view can't place (a small action's) opens as before.
  s.act("view-picture", (el) => {
    const p = postFrom(el);
    const list = (p && state.pictures[p.id]) || [];
    const i = parseInt(el.getAttribute("data-pic") || "", 10);
    if (list[i]) viewPicture(list, i);
    else {
      const href = el.getAttribute("href");
      if (href) window.open(href, "_blank", "noopener");
    }
  });
  s.act("spoiler", (el) => el.classList.toggle("revealed"));

  // ── Topic menu ──────────────────────────────────────────────────────

  const topicMenu = () => {
    const d = t.details || {};
    const items: SheetItem[] = [];
    if (d.can_create_post !== false)
      items.push({
        label: "Reply to topic",
        icon: "reply",
        hint: "3",
        run: () => reply(null),
      });
    items.push({
      label: "Notifications: " + levelLabel(state.level),
      icon: "bell",
      run: () =>
        topicLevelSheet(t.id, state.level, (lvl) => {
          state.level = lvl;
          invalidate(`/t/${t.id}`);
        }),
    });
    items.push({
      label: "Jump to post…",
      icon: "jump",
      hint: "9",
      run: askJump,
    });
    items.push({
      label: "First post",
      icon: "arrowUp",
      hint: "1",
      run: () => jumpTo(1),
    });
    items.push({
      label: "Last post",
      icon: "arrowDown",
      hint: "7",
      run: () => jumpTo(t.highest_post_number),
    });
    items.push({
      label: "Refresh",
      icon: "refresh",
      run: () => go(ctx.path + location.search, { replace: true }),
    });
    items.push({
      label: "Copy link",
      icon: "link",
      run: () => {
        const url =
          location.protocol +
          "//" +
          location.host +
          settings.subfolder +
          "/t/" +
          t.slug +
          "/" +
          t.id;
        if (copyText(url)) toast("Link copied.", "success");
        else
          void promptDialog("Link to this topic", { value: url, ok: "Done" });
      },
    });
    if (d.can_create_post !== false)
      whisperItems(null).forEach((w) => items.push(w));
    const hooks = {
      reload: reloadTopic,
      gone: (message: string) => {
        toast(message, "success");
        invalidate();
        go("/", { replace: true });
      },
    };
    const mod = topicStaffItems(t, hooks);
    if (canSelectPosts(t))
      mod.unshift({
        label: "Select posts…",
        icon: "check",
        run: startSelecting,
      });
    if (
      d.can_edit &&
      t.archetype !== "private_message" &&
      (isStaffUser() || d.can_moderate_category)
    )
      mod.push({
        label: "Change category…",
        icon: "grid",
        run: () =>
          chooseCategory(
            "Move to which category?",
            (categoryId) =>
              put(`/t/-/${t.id}.json`, { category_id: categoryId }).then(
                () => reloadTopic("Category changed."),
                fail
              ),
            t.category_id
          ),
      });
    topicModToolItems(t, hooks).forEach((x) => mod.push(x));
    if (mod.length) {
      items.push({ label: "Moderation", heading: true });
      for (let i = 0; i < mod.length; i++) items.push(mod[i]);
    }
    actionSheet(decodeEntities(t.fancy_title || t.title), items);
  };

  const askJump = () => {
    promptDialog(`Post number (1–${t.highest_post_number})`, {
      title: "Jump to post",
      type: "number",
      ok: "Go",
    }).then((v) => {
      const n = parseInt(v || "", 10);
      if (n) jumpTo(n);
    });
  };

  s.act("topic-menu", topicMenu);
  s.softkeys({ right: { label: "Options", run: topicMenu } });

  // ── Selecting posts ─────────────────────────────────────────────────

  let selecting = false;
  let selected: number[] = [];

  const paintSelection = () => {
    $$(".post[data-post]", container).forEach((el) => {
      const on =
        selecting &&
        selected.indexOf(parseInt(el.getAttribute("data-post") || "0", 10)) >=
          0;
      toggleClass(el, "selected", on);
      if (selecting) el.setAttribute("aria-selected", on ? "true" : "false");
      else el.removeAttribute("aria-selected");
    });
    toggleClass(document.documentElement, "selecting", selecting);
  };

  const selectionKeys = () =>
    s.softkeys({
      right: selecting
        ? {
            label: selected.length ? `${selected.length} selected` : "Select",
            run: () => selectionMenu(selection()),
          }
        : { label: "Options", run: topicMenu },
    });

  const selection = (): Selection => {
    const el = focusedPost();
    return {
      topic: t,
      stream: state.stream,
      posts: state.posts,
      selected,
      focused: el
        ? state.posts[parseInt(el.getAttribute("data-post") || "0", 10)] || null
        : null,
      set: (ids) => {
        selected = ids;
        paintSelection();
        selectionKeys();
      },
      stop: stopSelecting,
      leave: (message, path) => {
        toast(message, "success");
        invalidate();
        if (path) go(path);
        else go(ctx.path + location.search, { replace: true });
      },
      reload: reloadTopic,
    };
  };

  function startSelecting() {
    selecting = true;
    selected = [];
    paintSelection();
    selectionKeys();
    toast("OK on a post selects it.");
  }

  function stopSelecting() {
    selecting = false;
    selected = [];
    paintSelection();
    selectionKeys();
  }
  state.onPosts = paintSelection;
  s.onLeave(() => toggleClass(document.documentElement, "selecting", false));

  const nextPost = (dir: 1 | -1) => {
    const posts = $$(".post", container);
    const cur = focusedPost();
    let idx = cur ? posts.indexOf(cur) : -1;
    if (idx < 0) {
      // Start from the first post on screen.
      const top = (byId("topbar") as HTMLElement).offsetHeight;
      for (let i = 0; i < posts.length; i++)
        if (posts[i].getBoundingClientRect().bottom > top) {
          idx = i - (dir > 0 ? 1 : 0);
          break;
        }
    }
    const next = posts[idx + dir];
    if (next) focus(next);
    else if (dir > 0) {
      if (state.loadedTo < state.stream.length) void loadLater();
      else focusByKey("reply");
    } else {
      if (state.loadedFrom > 0) void loadEarlier();
      else focusByKey("head");
    }
  };

  s.keys({
    right: () => nextPost(1),
    left: () => nextPost(-1),
    "3": () => {
      const el = focusedPost();
      reply(
        el
          ? state.posts[parseInt(el.getAttribute("data-post") || "0", 10)] ||
              null
          : null
      );
    },
    "5": () => {
      const el = focusedPost();
      const p = el
        ? state.posts[parseInt(el.getAttribute("data-post") || "0", 10)]
        : null;
      if (p) toggleLike(p);
      else toast("Move to a post first.");
    },
    "9": askJump,
    "1": () => jumpTo(1),
    "7": () => jumpTo(t.highest_post_number),
  });

  // ── Read tracking ───────────────────────────────────────────────────

  const timings: Record<number, number> = {};
  let topicTime = 0;
  let lastTick = Date.now();
  const tick = () => {
    const now = Date.now();
    const dt = Math.min(now - lastTick, 5000);
    lastTick = now;
    if (document.hidden) return;
    topicTime += dt;
    const top = (byId("topbar") as HTMLElement).offsetHeight;
    const bottom = window.innerHeight || 400;
    const posts = $$(".post", container);
    for (let i = 0; i < posts.length; i++) {
      const r = posts[i].getBoundingClientRect();
      if (r.bottom > top && r.top < bottom) {
        const n = postKeyNumber(posts[i]);
        if (n) timings[n] = (timings[n] || 0) + dt;
      }
    }
  };
  const flush = () => {
    const payload: Record<string, number> = {};
    let any = false;
    for (const k in timings) {
      if (timings.hasOwnProperty(k) && timings[k] >= 1000) {
        payload[k] = timings[k];
        any = true;
      }
    }
    if (!any) return;
    for (const k in payload)
      if (payload.hasOwnProperty(k)) delete timings[k as unknown as number];
    const time = topicTime;
    topicTime = 0;
    apiPost(
      "/topics/timings.json",
      { topic_id: t.id, topic_time: time, timings: payload },
      { urlencoded: true }
    ).then(
      () => invalidate("/latest"),
      () => undefined
    );
  };
  const ticker = setInterval(tick, 1000);
  const flusher = setInterval(flush, 15000);
  s.onLeave(() => {
    clearInterval(ticker);
    clearInterval(flusher);
    tick();
    // Count at least the screen you saw.
    flush();
  });

  // ── Who's typing ────────────────────────────────────────────────────

  if (prefs.live) watchTyping(s, t.id);

  // ── Live updates ────────────────────────────────────────────────────

  if (prefs.live) {
    s.onLeave(
      subscribe(
        `/topic/${t.id}`,
        (data) => {
          const d = data as {
            type?: string;
            id?: number;
            post_number?: number;
          };
          if (!s.alive() || !d || !d.id) return;
          if (
            (d.type === "revised" ||
              d.type === "rebaked" ||
              d.type === "acted" ||
              d.type === "deleted" ||
              d.type === "recovered") &&
            state.posts[d.id]
          ) {
            void refreshPost(d.id);
          } else if (d.type === "created" && !state.posts[d.id]) {
            if (state.stream.indexOf(d.id) < 0) state.stream.push(d.id);
            if (state.loadedTo === state.stream.length - 1) {
              get<Post>(`/posts/${d.id}.json`).then(
                (p) => {
                  if (!s.alive() || !p || !p.id || state.posts[p.id]) return;
                  appendPosts(state, container, [p], "end");
                  state.loadedTo = state.stream.length;
                  updateEdges(state);
                  if (user && p.username !== user.username)
                    toast(`New reply from @${p.username}`);
                },
                () => undefined
              );
            } else {
              updateEdges(state);
            }
          }
        },
        typeof t.message_bus_last_id === "number" ? t.message_bus_last_id : -1
      )
    );
  }
}

// "alice is typing…", from Discourse's presence channel for replies.
function watchTyping(s: Screen, topicId: number): void {
  const channel = `/discourse-presence/reply/${topicId}`;
  const typing: Record<number, string> = {};
  const paint = () => {
    const box = byId("typing");
    if (!box) return;
    const names: string[] = [];
    for (const id in typing)
      if (typing.hasOwnProperty(id)) names.push(typing[id]);
    box.hidden = !names.length;
    box.textContent = !names.length
      ? ""
      : names.length === 1
        ? `${names[0]} is typing…`
        : names.length === 2
          ? `${names[0]} and ${names[1]} are typing…`
          : `${names.length} people are typing…`;
  };
  const me = user ? user.id : 0;
  get<
    Record<
      string,
      {
        users?: Array<{ id: number; username: string }>;
        last_message_id?: number;
      }
    >
  >(`/presence/get?channels[]=${encodeURIComponent(channel)}`).then(
    (d) => {
      if (!s.alive()) return;
      const state = d && d[channel];
      if (!state) return;
      (state.users || []).forEach((u) => {
        if (u.id !== me) typing[u.id] = u.username;
      });
      paint();
      s.onLeave(
        subscribe(
          "/presence" + channel,
          (data) => {
            const m = data as {
              entering_users?: Array<{ id: number; username: string }>;
              leaving_user_ids?: number[];
            };
            (m.entering_users || []).forEach((u) => {
              if (u.id !== me) typing[u.id] = u.username;
            });
            (m.leaving_user_ids || []).forEach((id) => delete typing[id]);
            paint();
          },
          typeof state.last_message_id === "number" ? state.last_message_id : -1
        )
      );
    },
    () => undefined
  );
}

function loadImage(el: HTMLElement): void {
  const src = el.getAttribute("data-src");
  if (!src) return;
  const img = document.createElement("img");
  img.src = src;
  img.alt = "";
  const w = el.getAttribute("data-w");
  const h = el.getAttribute("data-h");
  if (w) img.setAttribute("width", w);
  if (h) img.setAttribute("height", h);
  img.className = "loaded-image";
  // A post's picture: tapping it once it's shown opens the viewer on it.
  const pic = el.getAttribute("data-pic");
  if (pic) {
    img.setAttribute("data-act", "view-picture");
    img.setAttribute("data-pic", pic);
  }
  if (el.parentNode) el.parentNode.replaceChild(img, el);
  else removeNode(el);
}

function excerptOf(p: Post): string {
  const text = cookedToText(p.cooked || "").replace(/\s+/g, " ");
  return text.length > 90 ? text.slice(0, 89) + "…" : text;
}

function hostOf(url: string): string {
  const m = /^https?:\/\/([^/?#]+)/i.exec(url);
  return m ? m[1].replace(/^www\./, "") : "";
}

function participants(
  state: State
): Array<{ username: string; avatar_template: string }> {
  const seen: Record<string, boolean> = {};
  const out: Array<{ username: string; avatar_template: string }> = [];
  for (const id in state.posts) {
    if (!state.posts.hasOwnProperty(id)) continue;
    const p = state.posts[id];
    if (seen[p.username] || (user && p.username === user.username)) continue;
    seen[p.username] = true;
    out.push({ username: p.username, avatar_template: p.avatar_template });
  }
  return out;
}
