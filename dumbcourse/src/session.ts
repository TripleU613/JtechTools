// Who is signed in, and their live counters (notifications, messages,
// review queue, REQ-PM requests).

import { del, get } from "./api.ts";
import { invalidate } from "./cache.ts";
import { settings, type BootUser } from "./config.ts";
import { claimFor } from "./storage.ts";

export let user: BootUser | null = settings.currentUser;
const listeners: Array<() => void> = [];

claimFor(user ? user.id : null);

export function onUserChange(fn: () => void): void {
  listeners.push(fn);
}

function emit(): void {
  for (let i = 0; i < listeners.length; i++) listeners[i]();
}

export function loggedIn(): boolean {
  return !!user;
}

export function isStaff(): boolean {
  return !!user && (user.admin || user.moderator);
}

export function isMe(username: string | null | undefined): boolean {
  return (
    !!user &&
    !!username &&
    user.username.toLowerCase() === String(username).toLowerCase()
  );
}

export function updateCounts(data: Partial<BootUser>): void {
  if (!user) return;
  const u = user as unknown as Record<string, unknown>;
  const d = data as unknown as Record<string, unknown>;
  let changed = false;
  for (const k in d) {
    if (d.hasOwnProperty(k) && typeof d[k] === "number" && u[k] !== d[k]) {
      u[k] = d[k];
      changed = true;
    }
  }
  if (changed) emit();
}

interface CurrentUserJson {
  current_user?: Record<string, unknown>;
}

// Discourse's /session/current.json, mapped onto our BootUser shape.
export function fromCurrentUser(cu: Record<string, unknown>): BootUser {
  const reqpm = (cu.reqpm || {}) as {
    available?: boolean;
    incoming_count?: number;
  };
  const election = (cu.mod_election || {}) as {
    status?: string;
    voter?: boolean;
    voted?: boolean;
  };
  return {
    id: cu.id as number,
    username: cu.username as string,
    name: (cu.name as string) || null,
    avatar_template: cu.avatar_template as string,
    admin: !!cu.admin,
    moderator: !!cu.moderator,
    trust_level: (cu.trust_level as number) || 0,
    can_send_private_messages: !!cu.can_send_private_messages,
    // Not in /session/current.json (Discourse keeps them with the site
    // data): kept from boot, which signing in reloads.
    can_tag_topics: user ? user.can_tag_topics : false,
    can_create_tag: user ? user.can_create_tag : false,
    can_review: !!cu.can_review,
    reviewable_count: (cu.reviewable_count as number) || 0,
    unread_notifications: (cu.unread_notifications as number) || 0,
    unread_high_priority_notifications:
      (cu.unread_high_priority_notifications as number) || 0,
    all_unread_notifications_count:
      (cu.all_unread_notifications_count as number) || 0,
    new_personal_messages_notifications_count:
      (cu.new_personal_messages_notifications_count as number) || 0,
    reqpm_available: !!reqpm.available,
    reqpm_incoming_count: reqpm.incoming_count || 0,
    mod_election_vote_due:
      election.status === "voting" && election.voter && !election.voted ? 1 : 0,
    can_pair_devices: user ? user.can_pair_devices : settings.auth.pairing,
    second_factor_enabled: !!cu.second_factor_enabled,
    can_change_post_owner: !!cu.can_change_post_owner,
    whisperer: !!cu.whisperer,
  };
}

export function refreshUser(): Promise<BootUser | null> {
  return get<CurrentUserJson>("/session/current.json", {
    allowUnauthorized: true,
  }).then(
    (d) => {
      const next = d && d.current_user ? fromCurrentUser(d.current_user) : null;
      setUser(next);
      return next;
    },
    () => user
  );
}

export function setUser(next: BootUser | null): void {
  const changedAccount = (user ? user.id : null) !== (next ? next.id : null);
  user = next;
  claimFor(next ? next.id : null);
  if (changedAccount) invalidate();
  emit();
}

export function logout(): Promise<void> {
  const name = user ? user.username : "";
  // Whatever the server says, this device forgets the account.
  const done = () => {
    setUser(null);
  };
  return del("/session/" + encodeURIComponent(name) + ".json", undefined, {
    allowUnauthorized: true,
  }).then(done, done);
}

export function unreadNotifications(): number {
  if (!user) return 0;
  return (
    user.all_unread_notifications_count ||
    user.unread_notifications + user.unread_high_priority_notifications
  );
}
