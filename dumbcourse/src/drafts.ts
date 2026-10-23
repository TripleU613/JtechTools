// Composer drafts, saved on this phone for the signed-in account only and
// wiped on logout.

import { userGet, userSet } from "./storage.ts";

// A tag on a new topic: one picked from the forum's has its id; one typed
// in that doesn't exist yet has only a name.
export interface TagRef {
  id?: number;
  name: string;
}

export interface Draft {
  key: string;
  kind: "reply" | "topic" | "message" | "edit";
  text: string;
  title?: string;
  categoryId?: number | null;
  tags?: TagRef[];
  to?: string;
  topicId?: number;
  topicTitle?: string;
  postId?: number;
  replyTo?: { postNumber: number; username: string } | null;
  updatedAt: number;
}

const KEY = "drafts";

function all(): Record<string, Draft> {
  return userGet<Record<string, Draft>>(KEY, {});
}

export function getDraft(key: string): Draft | null {
  return all()[key] || null;
}

export function saveDraft(d: Draft): void {
  const drafts = all();
  if (!d.text.replace(/\s+/g, "") && !(d.title || "").replace(/\s+/g, "")) {
    delete drafts[d.key];
  } else {
    d.updatedAt = Date.now();
    drafts[d.key] = d;
  }
  // Keep the newest 50.
  const keys: string[] = [];
  for (const k in drafts) if (drafts.hasOwnProperty(k)) keys.push(k);
  if (keys.length > 50) {
    keys.sort((a, b) => drafts[a].updatedAt - drafts[b].updatedAt);
    for (let i = 0; i < keys.length - 50; i++) delete drafts[keys[i]];
  }
  userSet(KEY, drafts);
}

export function clearDraft(key: string): void {
  const drafts = all();
  delete drafts[key];
  userSet(KEY, drafts);
}

export function listDrafts(): Draft[] {
  const drafts = all();
  const out: Draft[] = [];
  for (const k in drafts) if (drafts.hasOwnProperty(k)) out.push(drafts[k]);
  out.sort((a, b) => b.updatedAt - a.updatedAt);
  return out;
}

// Drafts the old app kept, moved over once if they belong to this account.
export function adoptLegacyDrafts(
  userId: number,
  legacyOwner: string | null,
  legacy: string | null
): void {
  if (!legacy || String(userId) !== String(legacyOwner || "")) return;
  let parsed: Record<
    string,
    { text?: string; meta?: { topicTitle?: string } } | string
  > = {};
  try {
    parsed = JSON.parse(legacy) || {};
  } catch {
    return;
  }
  for (const k in parsed) {
    if (!parsed.hasOwnProperty(k)) continue;
    const v = parsed[k];
    const text = typeof v === "string" ? v : (v && v.text) || "";
    if (!text) continue;
    const m = /^reply_(\d+)$/.exec(k);
    if (m) {
      saveDraft({
        key: "reply:" + m[1],
        kind: "reply",
        text,
        topicId: parseInt(m[1], 10),
        topicTitle:
          typeof v === "object" && v.meta ? v.meta.topicTitle || "" : "",
        updatedAt: Date.now(),
      });
    }
  }
}
