// The staff side of a post's menu: everything core's post admin menu (the
// wrench under a post) offers, and this plugin's own post tools (pin to the
// bottom, whisper audience). Each item shows under the condition the full
// site uses, and calls the endpoint it calls, so the server's checks are the
// same. Also a post's edit history, which anyone may read where core allows.

import { del, get, post as apiPost, put } from "../api.ts";
import { settings } from "../config.ts";
import { processCooked } from "../content/cooked.ts";
import { $, setHtml } from "../dom.ts";
import { timeAgo, truncate } from "../format.ts";
import { html } from "../html.ts";
import { href } from "../router.ts";
import { user } from "../session.ts";
import type { Post, Topic } from "../types.ts";
import { icon } from "../ui/icons.ts";
import {
  confirmDialog,
  openLayer,
  promptDialog,
  type SheetItem,
  toast,
} from "../ui/layers.ts";
import {
  askText,
  askUsername,
  canManageTopic,
  choose,
  fail,
  isStaffUser,
} from "./staff-common.ts";

// What the topic screen does after a change to a post.
export interface PostStaffHooks {
  // Re-fetch and redraw the one post.
  refresh: (postId: number, message: string) => void;
  // Reload the whole topic (the post moved, or the topic changed).
  reload: (message: string) => void;
}

const POST_TYPES = { regular: 1, moderator_action: 2, whisper: 4 };

interface Badge {
  id: number;
  name: string;
  enabled?: boolean;
  manually_grantable?: boolean;
  multiple_grant?: boolean;
}

function isFirst(p: Post): boolean {
  return p.post_number === 1;
}

export function postStaffItems(
  p: Post,
  t: Topic,
  hooks: PostStaffHooks
): SheetItem[] {
  const staff = isStaffUser();
  const d = t.details || {};
  const items: SheetItem[] = [];
  const done = (message: string) => () => hooks.refresh(p.id, message);

  if (staff)
    items.push({
      label: "Review history",
      icon: "review",
      href: href("/review?topic_id=" + t.id + "&status=all"),
    });

  if (staff && p.post_type !== POST_TYPES.whisper)
    items.push({
      label:
        p.post_type === POST_TYPES.moderator_action
          ? "Back to a regular post"
          : "Staff colour",
      icon: "shield",
      run: () =>
        put(`/posts/${p.id}/post_type.json`, {
          post_type:
            p.post_type === POST_TYPES.moderator_action
              ? POST_TYPES.regular
              : POST_TYPES.moderator_action,
        }).then(
          done(
            p.post_type === POST_TYPES.moderator_action
              ? "Back to a regular post."
              : "Staff colour on."
          ),
          fail
        ),
    });

  if (d.can_edit_staff_notes)
    items.push({
      label:
        p.notice && p.notice.type === "custom"
          ? "Post notice…"
          : "Add post notice…",
      icon: "info",
      run: () => noticeMenu(p, hooks),
    });

  if (staff && p.hidden)
    items.push({
      label: "Unhide",
      icon: "eye",
      run: () =>
        put(`/posts/${p.id}/unhide.json`).then(done("Post unhidden."), fail),
    });

  if (user && user.can_change_post_owner)
    items.push({
      label: "Change owner…",
      icon: "user",
      run: () => changeOwner(t, [p.id], (message) => hooks.reload(message)),
    });

  if (staff && p.user_id > 0) {
    if (settings.staff && settings.staff.badgesEnabled)
      items.push({
        label: "Grant badge…",
        icon: "award",
        run: () => grantBadgeTo(p.username, postUrl(p, t)),
      });
    items.push({
      label: p.locked ? "Unlock post" : "Lock post",
      icon: p.locked ? "unlock" : "lock",
      hint: p.locked ? undefined : "Only staff can edit it",
      run: () =>
        put(`/posts/${p.id}/locked.json`, { locked: !p.locked }).then(
          done(p.locked ? "Post unlocked." : "Post locked."),
          fail
        ),
    });
  }

  if (
    p.deleted_at &&
    (isFirst(p) ? d.can_permanently_delete : p.can_permanently_delete)
  )
    items.push({
      label: "Delete permanently",
      icon: "trash",
      danger: true,
      run: () =>
        confirmDialog(
          isFirst(p)
            ? "Delete this topic permanently? It can't be restored afterwards."
            : "Delete this post permanently? It can't be restored afterwards.",
          { ok: "Delete permanently", danger: true }
        ).then((ok) => {
          if (ok)
            del(`/posts/${p.id}.json`, { force_destroy: true }).then(
              () => hooks.reload("Deleted permanently."),
              fail
            );
        }),
    });

  if (canManageTopic() || p.can_wiki)
    items.push({
      label: p.wiki ? "Stop being a wiki" : "Make wiki",
      icon: "edit",
      hint: p.wiki ? undefined : "Anyone can edit it",
      run: () =>
        put(`/posts/${p.id}/wiki.json`, { wiki: !p.wiki }).then(
          done(p.wiki ? "No longer a wiki." : "Now a wiki."),
          fail
        ),
    });

  if (p.post_number === 1 && d.can_publish_page)
    items.push({
      label: t.published_page ? "Published page…" : "Publish as a page…",
      icon: "external",
      hint: t.published_page ? "/pub/" + t.published_page.slug : undefined,
      run: () => publishPage(t, hooks),
    });

  // Core's nested view keeps pinned replies to the topic at the top.
  if (
    staff &&
    t.is_nested_view &&
    p.post_number > 1 &&
    (!p.reply_to_post_number || p.reply_to_post_number === 1)
  )
    items.push({
      label: "Pin or unpin in nested replies",
      icon: "pin",
      run: () =>
        put<{ pinned_post_ids?: number[] }>(`/n/${t.slug}/${t.id}/pin.json`, {
          post_id: p.id,
        }).then(
          (r) =>
            toast(
              (r.pinned_post_ids || []).indexOf(p.id) >= 0
                ? "Pinned at the top of nested replies."
                : "Unpinned.",
              "success"
            ),
          fail
        ),
    });

  if (canManageTopic())
    items.push({
      label: "Rebuild HTML",
      icon: "refresh",
      run: () =>
        put(`/posts/${p.id}/rebake.json`).then(done("HTML rebuilt."), fail),
    });

  // ── This plugin's post tools ────────────────────────────────────────
  if (
    staff &&
    "mod_topic_pinned_post_id" in (t as object) &&
    !p.mod_is_whisper
  ) {
    const pinned =
      (t as Topic & { mod_topic_pinned_post_id?: number | null })
        .mod_topic_pinned_post_id === p.id;
    items.push({
      label: pinned ? "Unpin from the bottom" : "Pin to the bottom",
      icon: "pin",
      run: () =>
        put(`/discourse-mod-categories/topic/${t.id}`, {
          pinned_post_id: pinned ? "" : p.id,
        }).then(
          () => hooks.reload(pinned ? "Unpinned." : "Pinned to the bottom."),
          fail
        ),
    });
  }
  if (staff && p.mod_is_whisper && settings.staff) {
    if (settings.staff.whisperAddParticipant)
      items.push({
        label: "Add someone to this whisper…",
        icon: "user",
        run: () =>
          askUsername("Add to this whisper", (username) =>
            apiPost(
              `/discourse-mod-categories/topic/${t.id}/whisper-participant`,
              { post_id: p.id, username }
            ).then(done("Added to the whisper."), fail)
          ),
      });
    if (settings.staff.whisperConvert)
      items.push({
        label: "Make public",
        icon: "eye",
        run: () =>
          confirmDialog(
            "Make this whisper an ordinary post everyone here can read?",
            { ok: "Make public" }
          ).then((ok) => {
            if (ok)
              put(`/discourse-mod-categories/post/${p.id}/whisper`, {
                mod_whisper: false,
              }).then(done("Now a public post."), fail);
          }),
      });
  }

  return items;
}

// ── Published page ─────────────────────────────────────────────────────

function publishPage(t: Topic, hooks: PostStaffHooks): void {
  const page = t.published_page;
  const publish = (slug: string, isPublic: boolean, message: string) =>
    get<{ valid_slug?: boolean; reason?: string }>(
      `/pub/check-slug.json?slug=${encodeURIComponent(slug)}`
    ).then((c) => {
      if (c && c.valid_slug === false && !(page && page.slug === slug)) {
        toast(c.reason || "That address can't be used.", "error");
        return;
      }
      put(`/pub/by-topic/${t.id}.json`, {
        published_page: { slug, public: isPublic },
      }).then(() => hooks.reload(message), fail);
    }, fail);
  const askSlug = (value: string, isPublic: boolean, message: string) =>
    promptDialog("Its address: /pub/…", {
      title: "Publish as a page",
      value,
      ok: "Publish",
    }).then((v) => {
      const slug = (v || "").replace(/^\s+|\s+$/g, "");
      if (slug) publish(slug, isPublic, message);
    });
  if (!page) {
    askSlug(t.slug, false, "Published as a page.");
    return;
  }
  choose(
    "Published page",
    [
      { label: "Change its address", value: "slug" },
      {
        label: page.public ? "Only members can see it" : "Anyone can see it",
        value: "public",
      },
      { label: "Unpublish", value: "remove", danger: true },
    ],
    (v) => {
      if (v === "slug") askSlug(page.slug, !!page.public, "Address changed.");
      else if (v === "public")
        publish(
          page.slug,
          !page.public,
          page.public ? "Now for members only." : "Now public."
        );
      else
        del(`/pub/by-topic/${t.id}.json`).then(
          () => hooks.reload("Unpublished."),
          fail
        );
    },
    "/pub/" + page.slug
  );
}

// ── Post notice ────────────────────────────────────────────────────────

function noticeMenu(p: Post, hooks: PostStaffHooks): void {
  const current =
    p.notice && p.notice.type === "custom" ? p.notice.raw || "" : "";
  const save = (notice: string) =>
    put(`/posts/${p.id}/notice.json`, { notice }).then(
      () => hooks.refresh(p.id, notice ? "Notice saved." : "Notice removed."),
      fail
    );
  const write = () =>
    askText(
      "Post notice",
      "Shown above the post to everyone",
      (text) => save(text),
      { value: current, ok: "Save" }
    );
  if (!current) {
    write();
    return;
  }
  choose(
    "Post notice",
    [
      { label: "Change it", value: "edit" },
      { label: "Remove it", value: "remove", danger: true },
    ],
    (v) => (v === "edit" ? write() : save("")),
    truncate(current, 80)
  );
}

// ── Change owner ───────────────────────────────────────────────────────

export function changeOwner(
  t: Topic,
  postIds: number[],
  after: (message: string) => void
): void {
  askUsername(
    postIds.length === 1
      ? "Change owner"
      : `Change owner of ${postIds.length} posts`,
    (username) =>
      apiPost(`/t/${t.id}/change-owner.json`, {
        post_ids: postIds,
        username,
      }).then(() => after("Owner changed to @" + username + "."), fail),
    "New owner's username"
  );
}

// ── Grant badge ────────────────────────────────────────────────────────

// A badge for `username`, from the ones staff may hand out; `reason` is a
// link to what earned it, when there is one.
export function grantBadgeTo(username: string, reason?: string): void {
  Promise.all([
    get<{ badges?: Badge[] }>("/badges.json"),
    get<{ user_badges?: Array<{ badge_id: number }> }>(
      `/user-badges/${encodeURIComponent(username)}.json`
    ),
  ]).then((res) => {
    const owned: Record<number, boolean> = {};
    (res[1].user_badges || []).forEach((b) => (owned[b.badge_id] = true));
    const badges = (res[0].badges || [])
      .filter(
        (b) =>
          b.enabled !== false &&
          b.manually_grantable &&
          (!owned[b.id] || b.multiple_grant)
      )
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    if (!badges.length) {
      toast("No badges to grant.", "error");
      return;
    }
    choose(
      "Grant @" + username + " a badge",
      badges.map((b) => ({ label: b.name, value: String(b.id) })),
      (id) =>
        apiPost("/user_badges.json", {
          username,
          badge_id: parseInt(id, 10),
          reason: reason || undefined,
        }).then(() => toast("Badge granted.", "success"), fail)
    );
  }, fail);
}

function postUrl(p: Post, t: Topic): string {
  return (
    location.protocol +
    "//" +
    location.host +
    settings.subfolder +
    `/t/${t.slug}/${t.id}/${p.post_number}`
  );
}

// ── Edit history ───────────────────────────────────────────────────────

interface Revision {
  current_revision: number;
  previous_revision?: number | null;
  next_revision?: number | null;
  first_revision?: number;
  last_revision?: number;
  current_version?: number;
  version_count?: number;
  username?: string;
  created_at?: string;
  edit_reason?: string | null;
  can_edit?: boolean;
  previous_hidden?: boolean;
  unlisted?: boolean;
  body_changes?: { inline?: string } | null;
  title_changes?: { inline?: string } | null;
}

export function canSeeHistory(p: Post): boolean {
  return (p.version || 1) > 1 && p.can_view_edit_history !== false;
}

export function editHistory(p: Post, onReverted: () => void): void {
  let rev: Revision | null = null;
  const layer = openLayer({
    kind: "full",
    label: "Edit history",
    className: "history-layer",
    body: html`<div class="history">
      <div class="c-head" data-row>
        <button type="button" class="tb-btn" data-h="close" aria-label="Close">
          ${icon("x")}
        </button>
        <div class="c-title">Edit history</div>
      </div>
      <div class="history-bar" data-row>
        <button type="button" class="btn small" data-h="older">‹ Older</button>
        <span class="history-pos" aria-live="polite"></span>
        <button type="button" class="btn small" data-h="newer">Newer ›</button>
      </div>
      <div class="history-body scroll" tabindex="0">
        <p class="state state-loading"><span class="spinner"></span>Loading…</p>
      </div>
      <div class="history-foot" data-row></div>
    </div>`,
    softkeys: { left: "Close", center: "Select", right: "Older" },
    focusSelector: ".history-body",
  });
  layer.el.setAttribute("data-softright", "[data-h=older]");

  const body = $(".history-body", layer.el) as HTMLElement;
  const pos = $(".history-pos", layer.el) as HTMLElement;
  const foot = $(".history-foot", layer.el) as HTMLElement;
  const older = $("[data-h=older]", layer.el) as HTMLButtonElement;
  const newer = $("[data-h=newer]", layer.el) as HTMLButtonElement;

  const show = (version: number | "latest") => {
    get<Revision>(`/posts/${p.id}/revisions/${version}.json`).then((r) => {
      rev = r;
      const n = r.current_version || r.current_revision;
      pos.textContent = `Version ${n} of ${r.version_count || n}`;
      older.disabled = !r.previous_revision || n <= 2;
      newer.disabled =
        !r.next_revision || r.current_revision >= (r.last_revision || 0);
      const title = r.title_changes && r.title_changes.inline;
      setHtml(
        body,
        html`<p class="history-who">
            ${r.username ? html`@${r.username}` : ""}${r.created_at
              ? html` · ${timeAgo(r.created_at)} ago`
              : ""}${r.edit_reason ? html` · ${r.edit_reason}` : ""}
          </p>
          ${title
            ? html`<div class="history-title cooked">
                ${processCooked(title).html}
              </div>`
            : ""}
          <div class="history-diff cooked">
            ${processCooked((r.body_changes && r.body_changes.inline) || "")
              .html}
          </div>`
      );
      const canRevert =
        isStaffUser() && r.can_edit !== false && r.current_revision >= 2;
      setHtml(
        foot,
        html`${canRevert
          ? html`<button type="button" class="btn small" data-h="revert">
              ${icon("undo")}Go back to the version before this
            </button>`
          : ""}${isStaffUser() && r.current_revision >= 2
          ? html`<button type="button" class="btn small" data-h="visibility">
              ${icon("eye")}Who sees this edit
            </button>`
          : ""}`
      );
    }, fail);
  };

  layer.el.addEventListener("click", (e) => {
    let target = e.target as HTMLElement | null;
    while (target && target !== layer.el && !target.getAttribute("data-h"))
      target = target.parentNode as HTMLElement | null;
    const what =
      target && target !== layer.el ? target.getAttribute("data-h") : "";
    if (!what || !rev) {
      if (what === "close") layer.close();
      return;
    }
    if (what === "close") layer.close();
    else if (what === "older" && rev.previous_revision)
      show(rev.previous_revision);
    else if (what === "newer" && rev.next_revision) show(rev.next_revision);
    else if (what === "visibility" && rev.current_revision >= 2) {
      const r = rev;
      const now = r.previous_hidden
        ? "hidden"
        : r.unlisted
          ? "unlisted"
          : "listed";
      // Core's steps from one to another (a hidden edit is shown first).
      const steps: Record<string, Record<string, string[]>> = {
        listed: { unlisted: ["unlist"], hidden: ["hide"] },
        unlisted: { listed: ["relist"], hidden: ["hide"] },
        hidden: { listed: ["show"], unlisted: ["show", "unlist"] },
      };
      choose(
        "Who sees this edit",
        [
          { label: "Everyone, in the history", value: "listed" },
          { label: "Everyone, but skipped in the list", value: "unlisted" },
          { label: "Staff only (hidden)", value: "hidden" },
        ].map((c) => ({
          label: c.label,
          value: c.value,
          active: c.value === now,
        })),
        (target) => {
          const todo = (steps[now] && steps[now][target]) || [];
          let chain: Promise<unknown> = Promise.resolve();
          todo.forEach((step) => {
            chain = chain.then(() =>
              put(`/posts/${p.id}/revisions/${r.current_revision}/${step}.json`)
            );
          });
          chain.then(() => {
            toast("Saved.", "success");
            show(r.current_revision);
          }, fail);
        }
      );
    } else if (what === "revert" && rev.current_revision >= 2) {
      // Core reverts a revision by putting back what it changed.
      const to = rev.current_revision;
      confirmDialog("Put the post back the way it was before this edit?", {
        ok: "Go back",
      }).then((ok) => {
        if (!ok) return;
        put(`/posts/${p.id}/revisions/${to}/revert.json`).then(() => {
          layer.close();
          toast("Post reverted.", "success");
          onReverted();
        }, fail);
      });
    }
  });

  show("latest");
}
