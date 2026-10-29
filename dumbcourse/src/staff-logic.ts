// The staff tools' pure pieces, kept free of the page so they can be tested
// on their own: reading typed dates and topic links, and putting the review
// queue's side-loaded JSON back together.

// "2026-11-05 14:30" or "2026-11-05", read as local time. Typed by hand on
// phones whose browsers show the date input as a plain text box.
export function parseLocalDateTime(value: string): Date | null {
  const m =
    /^\s*(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2}))?\s*$/.exec(
      value || ""
    );
  if (!m) return null;
  const d = new Date(
    parseInt(m[1], 10),
    parseInt(m[2], 10) - 1,
    parseInt(m[3], 10),
    m[4] ? parseInt(m[4], 10) : 8,
    m[5] ? parseInt(m[5], 10) : 0
  );
  return isNaN(d.getTime()) ? null : d;
}

// A topic's id from a link to it ("/t/slug/123", "/t/123/4") or its number.
export function topicIdFrom(value: string): number {
  const v = (value || "").replace(/^\s+|\s+$/g, "");
  if (/^\d+$/.test(v)) return parseInt(v, 10);
  // A slug has something other than digits in it; "/t/123/4" is topic 123.
  const m = /\/t\/(?:[^/?#]*[^\d/?#][^/?#]*\/)?(\d+)(?:[/?#]|$)/.exec(v);
  return m ? parseInt(m[1], 10) : 0;
}

// ── The review queue's JSON ─────────────────────────────────────────────
//
// A reviewable names its actions, scores, notes and claim by id, and the
// response lists them beside the reviewables (Discourse's rest serializer).
// Inline objects are taken as they are.

export interface ReviewAction {
  id: string;
  label: string;
  server_action?: string;
  client_action?: string;
  description?: string;
  confirm_message?: string;
  button_class?: string | null;
  require_reject_reason?: boolean;
}

export interface Bundle {
  id: string;
  label?: string;
  action_ids?: string[];
  actions?: ReviewAction[];
}

export interface Score {
  id: number;
  reason?: string | null;
  created_at?: string;
  user_id?: number;
  score_type?: { title?: string; type?: string };
}

export interface Note {
  id: number;
  content: string;
  created_at: string;
  user?: { id: number; username: string } | null;
}

export interface Claim {
  id: number;
  automatic?: boolean;
  user_id?: number;
  user?: { id: number; username: string } | null;
}

export interface UserRef {
  id: number;
  username: string;
  avatar_template: string;
}

export interface Reviewable {
  id: number;
  type: string;
  status: number;
  version: number;
  created_at: string;
  topic_id?: number;
  topic_url?: string;
  target_id?: number;
  target_type?: string;
  target_url?: string;
  category_id?: number;
  target_created_by_id?: number;
  created_by_id?: number;
  can_edit?: boolean;
  raw?: string;
  cooked?: string;
  topic_title?: string;
  fancy_title?: string;
  topic_fancy_title?: string;
  reply_to_post_number?: number | null;
  username?: string;
  email?: string;
  name?: string;
  payload?: {
    raw?: string;
    title?: string;
    username?: string;
    email?: string;
    name?: string;
  };
  editable_fields?: Array<{ id: string; type: string }>;
  bundled_action_ids?: string[];
  bundled_actions?: Bundle[];
  reviewable_score_ids?: number[];
  reviewable_scores?: Score[];
  reviewable_note_ids?: number[];
  reviewable_notes?: Note[];
  claimed_by?: Claim | null;
  claimed_by_id?: number | null;
}

export interface ReviewJson {
  reviewables?: Reviewable[];
  users?: UserRef[];
  bundled_actions?: Bundle[];
  actions?: ReviewAction[];
  reviewable_scores?: Score[];
  reviewable_notes?: Note[];
  claimed_bies?: Claim[];
  claimed_by?: Claim[];
  meta?: { total_rows_reviewables?: number; load_more_reviewables?: string };
}

function byId<T extends { id: number | string }>(
  list: T[] | undefined
): Record<string, T> {
  const out: Record<string, T> = {};
  (list || []).forEach((x) => (out[String(x.id)] = x));
  return out;
}

export interface Lookup {
  users: Record<string, UserRef>;
  bundles: Record<string, Bundle>;
  actions: Record<string, ReviewAction>;
  scores: Record<string, Score>;
  notes: Record<string, Note>;
  claims: Record<string, Claim>;
}

export function lookupOf(d: ReviewJson): Lookup {
  return {
    users: byId(d.users),
    bundles: byId(d.bundled_actions),
    actions: byId(d.actions),
    scores: byId(d.reviewable_scores),
    notes: byId(d.reviewable_notes),
    claims: byId(d.claimed_bies || d.claimed_by || []),
  };
}

export function actionsOf(r: Reviewable, l: Lookup): ReviewAction[] {
  const bundles: Bundle[] =
    r.bundled_actions ||
    (r.bundled_action_ids || []).map((id) => l.bundles[id]).filter((b) => !!b);
  const out: ReviewAction[] = [];
  bundles.forEach((b) => {
    const list =
      b.actions ||
      (b.action_ids || []).map((id) => l.actions[id]).filter((a) => !!a);
    list.forEach((a) => out.push(a));
  });
  return out;
}

export function scoresOf(r: Reviewable, l: Lookup): Score[] {
  return (
    r.reviewable_scores ||
    (r.reviewable_score_ids || []).map((id) => l.scores[id]).filter((s) => !!s)
  );
}

export function notesOf(r: Reviewable, l: Lookup): Note[] {
  return (
    r.reviewable_notes ||
    (r.reviewable_note_ids || []).map((id) => l.notes[id]).filter((n) => !!n)
  );
}

export function claimOf(
  r: Reviewable,
  l: Lookup
): { username: string; id: number } | null {
  const c =
    r.claimed_by || (r.claimed_by_id ? l.claims[r.claimed_by_id] : null);
  if (!c) return null;
  const u = c.user || (c.user_id ? l.users[c.user_id] : null);
  return u ? { username: u.username, id: u.id } : null;
}

// Core labels some actions just "Yes" and "No" (its buttons sit under a
// question); a menu item needs to say what it does.
export function actionLabel(a: ReviewAction): string {
  if (/^yes$/i.test(a.label)) return "Approve";
  if (/^no$/i.test(a.label)) return "Reject";
  return a.label;
}
