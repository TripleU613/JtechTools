import { ajax } from "discourse/lib/ajax";
import { CREATE_TOPIC } from "discourse/models/composer";
import type User from "discourse/models/user";
import { type PrecheckComposer, REPLY_ACTION } from "./precheck-prompt.ts";

export interface ChecklistItem {
  label: string;
  url?: string;
}

// The checklist a user owes: the shape of both the
// `mod_first_post_checklist` serializer and `/checklist/owed`.
export interface OwedChecklist {
  kind?: "global" | "topic" | "targeted";
  id?: number | string;
  version: number;
  mode?: "checklist" | "statement";
  statement?: string;
  items?: ChecklistItem[];
  frequency?: "once" | "every_reply";
  max_tl?: number;
  button_label?: string;
  updated_at?: string | null;
}

export type ChecklistUser = User & {
  mod_first_post_checklist?: OwedChecklist | null;
};

interface OwedChecklistResponse {
  checklist: OwedChecklist | null;
}

// The first-post checklist the current user must complete before this
// composer save, or null when nothing should gate it.
//
// `currentUser.mod_first_post_checklist` carries the owed checklist. It is
// bootstrapped on a full page load, but Discourse is a single-page app, so
// after the user accepts once (which clears it to null) or staff bump the
// version mid-session, the bootstrapped value goes stale. `refreshOwedChecklist`
// re-syncs it from the server when the composer opens, so the gate below
// always reads the CURRENT server state — no hard page refresh needed.
export function firstPostChecklistFor(
  composer: PrecheckComposer | null | undefined,
  currentUser: ChecklistUser | null | undefined
): OwedChecklist | null {
  if (!composer || !currentUser) {
    return null;
  }

  if (composer.action !== CREATE_TOPIC && composer.action !== REPLY_ACTION) {
    return null;
  }

  const checklist = currentUser.mod_first_post_checklist;
  if (!checklist) {
    return null;
  }

  // Statement mode has no items by design — a non-blank statement is
  // what makes it active. Other modes require at least one item.
  if (checklist.mode === "statement") {
    if (!checklist.statement || !checklist.statement.trim()) {
      return null;
    }
    return checklist;
  }

  if (!checklist.items || checklist.items.length === 0) {
    return null;
  }

  return checklist;
}

// The id of the topic being replied to in this composer (or null when the
// composer is creating a new topic). The per-topic checklist gate keys on
// this so the server can include the topic-scoped checklist in the owed
// result.
export function composerTopicId(
  composer: PrecheckComposer | null | undefined
): number | null {
  if (!composer) {
    return null;
  }
  if (composer.action !== REPLY_ACTION) {
    return null;
  }
  const topic = composer.topic;
  return topic && topic.id ? topic.id : null;
}

// Re-fetches the current user's currently-owed checklist from the server
// and writes it onto `currentUser.mod_first_post_checklist`, so a checklist
// edited or version-bumped mid-session is gated without a hard refresh.
// Returns a promise; a failed request leaves the existing value untouched.
//
// When `topicId` is provided the server also considers the per-topic
// prompt checklist for that topic; priority is targeted > per-topic >
// global, so a user owing several is shown the highest-priority one.
export function refreshOwedChecklist(
  currentUser: ChecklistUser | null | undefined,
  topicId: number | null = null
): Promise<void> {
  if (!currentUser) {
    return Promise.resolve();
  }

  const url = topicId
    ? `/discourse-mod-categories/checklist/owed.json?topic_id=${encodeURIComponent(
        topicId
      )}`
    : "/discourse-mod-categories/checklist/owed.json";

  return ajax(url)
    .then((result: OwedChecklistResponse | null) => {
      currentUser.set("mod_first_post_checklist", result?.checklist ?? null);
    })
    .catch(() => {
      // Network error: keep whatever value we already have rather than
      // dropping a checklist the user genuinely owes.
    });
}
