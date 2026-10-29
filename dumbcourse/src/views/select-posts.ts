// Selecting posts in a topic, as the full site's "Select posts" does, and
// what staff can do with them: move them to a new or existing topic or
// message, merge them, change their owner, or delete them. Each action is
// offered under the condition core's selected-posts panel uses.

import { del, get, post as apiPost, put } from "../api.ts";
import { appPathFor } from "../content/cooked.ts";
import { user } from "../session.ts";
import type { Post, Topic } from "../types.ts";
import {
  actionSheet,
  confirmDialog,
  promptDialog,
  type SheetItem,
  toast,
} from "../ui/layers.ts";
import { changeOwner } from "./post-staff.ts";
import {
  canManageTopic,
  choose,
  chooseCategory,
  chooseTopic,
  fail,
  isStaffUser,
} from "./staff-common.ts";

export interface Selection {
  topic: Topic;
  // Post ids in topic order.
  stream: number[];
  // The posts loaded so far, by id.
  posts: Record<number, Post>;
  selected: number[];
  // The post that has focus, if any.
  focused: Post | null;
  set: (ids: number[]) => void;
  stop: () => void;
  // After posts moved or changed: where to go, or reload this topic.
  leave: (message: string, path: string | null) => void;
  reload: (message: string) => void;
}

// Core shows "Select posts" to topic managers and category moderators.
export function canSelectPosts(t: Topic): boolean {
  return canManageTopic() || !!(t.details && t.details.can_split_merge_topic);
}

function selectedPosts(s: Selection): Post[] {
  return s.selected.map((id) => s.posts[id]).filter((p) => !!p);
}

// The one author of the selection, if every selected post is loaded and
// they're all theirs.
function soleAuthor(s: Selection): string | undefined {
  const posts = selectedPosts(s);
  if (posts.length !== s.selected.length || !posts.length) return undefined;
  const name = posts[0].username;
  for (let i = 1; i < posts.length; i++)
    if (posts[i].username !== name) return undefined;
  return name;
}

function allSelected(s: Selection): boolean {
  return s.selected.length >= s.stream.length;
}

function unique(ids: number[]): number[] {
  const seen: Record<number, boolean> = {};
  return ids.filter((id) => (seen[id] ? false : (seen[id] = true)));
}

export function toggleSelected(s: Selection, id: number): void {
  const i = s.selected.indexOf(id);
  if (i >= 0) s.set(s.selected.slice(0, i).concat(s.selected.slice(i + 1)));
  else s.set(s.selected.concat([id]));
}

export function selectionMenu(s: Selection): void {
  const t = s.topic;
  const d = t.details || {};
  const n = s.selected.length;
  const posts = selectedPosts(s);
  const author = soleAuthor(s);
  const items: SheetItem[] = [];

  if (s.focused) {
    const p = s.focused;
    items.push({
      label:
        s.selected.indexOf(p.id) >= 0
          ? "Unselect this post"
          : "Select this post",
      icon: "check",
      run: () => toggleSelected(s, p.id),
    });
    items.push({
      label: "Select this and below",
      icon: "arrowDown",
      run: () => {
        const at = s.stream.indexOf(p.id);
        if (at >= 0) s.set(unique(s.selected.concat(s.stream.slice(at))));
      },
    });
    if (p.reply_count)
      items.push({
        label: "Select this and its replies",
        icon: "reply",
        run: () =>
          get<Array<{ id: number }>>(`/posts/${p.id}/reply-ids.json`).then(
            (replies) =>
              s.set(
                unique(
                  s.selected.concat(
                    [p.id],
                    (replies || []).map((r) => r.id)
                  )
                )
              ),
            fail
          ),
      });
  }
  if (n < s.stream.length)
    items.push({
      label: "Select all",
      icon: "check",
      run: () => s.set(s.stream.slice()),
    });
  if (n)
    items.push({ label: "Clear selection", icon: "x", run: () => s.set([]) });

  if (n) {
    items.push({ label: plural(n, "post") + " selected", heading: true });
    if (d.can_move_posts) {
      items.push({
        label: "Move to a new topic…",
        icon: "jump",
        run: () => moveToNewTopic(s),
      });
      items.push({
        label: "Move to an existing topic…",
        icon: "jump",
        run: () => moveToExisting(s, false),
      });
      items.push({
        label: "Move to a new message…",
        icon: "mail",
        run: () => moveToNewMessage(s),
      });
      items.push({
        label: "Move to an existing message…",
        icon: "mail",
        run: () => moveToExisting(s, true),
      });
    }
    if (n > 1 && author && posts.every((p) => !!p.can_delete))
      items.push({
        label: "Merge into one post",
        icon: "edit",
        run: () =>
          confirmDialog(`Merge these ${n} posts into one?`, {
            ok: "Merge",
          }).then((ok) => {
            if (ok)
              // Sent as text, as the full site does: core turns away ids that
              // match its own numbers exactly.
              put("/posts/merge_posts.json", {
                post_ids: s.selected.map(String),
              }).then(() => {
                s.stop();
                s.reload("Posts merged.");
              }, fail);
          }),
      });
    if (user && user.can_change_post_owner && author)
      items.push({
        label: "Change owner…",
        icon: "user",
        run: () =>
          changeOwner(t, s.selected, (message) => {
            s.stop();
            s.reload(message);
          }),
      });
    const canDelete =
      (allSelected(s) && isStaffUser()) ||
      (posts.length === n && posts.every((p) => !!p.can_delete));
    if (canDelete)
      items.push({
        label: "Delete selected",
        icon: "trash",
        danger: true,
        run: () => deleteSelected(s),
      });
  }
  items.push({ label: "Done selecting", icon: "check", run: s.stop });

  actionSheet(n ? plural(n, "post") + " selected" : "Select posts", items, {
    subtitle: n ? undefined : "OK on a post selects it.",
  });
}

function plural(n: number, word: string): string {
  return n + " " + word + (n === 1 ? "" : "s");
}

function moved(s: Selection, message: string) {
  return (res: unknown) => {
    const r = res as { url?: string } | null;
    s.stop();
    s.leave(message, r && r.url ? appPathFor(r.url) : null);
  };
}

function moveToNewTopic(s: Selection): void {
  promptDialog("Title of the new topic", {
    title: "Move to a new topic",
    ok: "Next",
  }).then((title) => {
    if (title === null) return;
    const name = title.replace(/^\s+|\s+$/g, "");
    if (!name) {
      toast("Give it a title.", "error");
      return;
    }
    chooseCategory(
      "In which category?",
      (categoryId) =>
        apiPost(`/t/${s.topic.id}/move-posts.json`, {
          title: name,
          post_ids: s.selected,
          category_id: categoryId,
        }).then(moved(s, "Moved to a new topic."), fail),
      s.topic.category_id
    );
  });
}

function moveToNewMessage(s: Selection): void {
  promptDialog("Title of the new message", {
    title: "Move to a new message",
    ok: "Next",
  }).then((title) => {
    if (title === null) return;
    const name = title.replace(/^\s+|\s+$/g, "");
    if (!name) {
      toast("Give it a title.", "error");
      return;
    }
    promptDialog("Who's in it (usernames, separated by commas)", {
      title: "Move to a new message",
      ok: "Move",
    }).then((who) => {
      if (who === null) return;
      apiPost(`/t/${s.topic.id}/move-posts.json`, {
        title: name,
        post_ids: s.selected,
        archetype: "private_message",
        participants: who.replace(/[@\s]+/g, ""),
      }).then(moved(s, "Moved to a new message."), fail);
    });
  });
}

function moveToExisting(s: Selection, messages: boolean): void {
  chooseTopic(
    messages ? "Move to which message?" : "Move to which topic?",
    (destination) =>
      choose(
        "Where they go",
        [
          { label: "At the end", value: "end" },
          { label: "In order of when they were posted", value: "date" },
        ],
        (order) => {
          const body: Record<string, unknown> = {
            destination_topic_id: destination,
            // Core checks for the text "true".
            chronological_order: order === "date" ? "true" : "false",
          };
          if (messages) {
            body.archetype = "private_message";
            body.participants = "";
          }
          // Every post at once is a merge of the whole topic.
          const whole = allSelected(s) && !messages;
          if (!whole) body.post_ids = s.selected;
          apiPost(
            `/t/${s.topic.id}/${whole ? "merge-topic" : "move-posts"}.json`,
            body
          ).then(moved(s, "Moved."), fail);
        }
      ),
    { messages, exclude: s.topic.id }
  );
}

function deleteSelected(s: Selection): void {
  const n = s.selected.length;
  const all = allSelected(s);
  confirmDialog(
    all
      ? "Delete every post? That deletes the whole topic."
      : `Delete ${plural(n, "post")}?`,
    { ok: "Delete", danger: true }
  ).then((ok) => {
    if (!ok) return;
    const req = all
      ? del(`/t/${s.topic.id}.json`)
      : del("/posts/destroy_many.json", { post_ids: s.selected });
    req.then(() => {
      s.stop();
      s.reload(all ? "Topic deleted." : "Deleted.");
    }, fail);
  });
}
