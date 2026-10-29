// What staff can do to a member from their profile: everything core's admin
// user page offers as an action (penalties, trust level, roles, approval,
// activation, badges, groups, IP lookup, logs, impersonation, deletion),
// plus staff notes and this plugin's per-user slow mode. Each item shows
// under the condition the server sends with the user (can_* fields), and
// calls the endpoint the admin page calls.

import { del, get, post as apiPost, put } from "../api.ts";
import { settings } from "../config.ts";
import { dateTime, longDate, timeAgo, truncate } from "../format.ts";
import { href } from "../router.ts";
import { user } from "../session.ts";
import { userPath } from "../site.ts";
import {
  actionSheet,
  alertDialog,
  confirmDialog,
  type SheetItem,
  toast,
} from "../ui/layers.ts";
import { openComposer } from "./composer.ts";
import { grantBadgeTo } from "./post-staff.ts";
import {
  askDate,
  askText,
  askUsername,
  type Choice,
  choose,
  chooseUntil,
  DAY,
  fail,
  isAdminUser,
  isStaffUser,
} from "./staff-common.ts";

interface AdminUser {
  id: number;
  username: string;
  admin: boolean;
  moderator: boolean;
  active: boolean;
  approved?: boolean;
  staged?: boolean;
  trust_level: number;
  manual_locked_trust_level?: number | null;
  suspended_till?: string | null;
  silenced_till?: string | null;
  full_suspend_reason?: string | null;
  full_silence_reason?: string | null;
  post_count?: number;
  ip_address?: string;
  registration_ip_address?: string;
  second_factor_enabled?: boolean;
  can_be_suspended?: boolean;
  can_be_deleted?: boolean;
  can_be_anonymized?: boolean;
  can_be_merged?: boolean;
  can_delete_all_posts?: boolean;
  can_impersonate?: boolean;
  can_grant_admin?: boolean;
  can_revoke_admin?: boolean;
  can_grant_moderation?: boolean;
  can_revoke_moderation?: boolean;
  can_approve?: boolean;
  can_activate?: boolean;
  can_deactivate?: boolean;
  can_send_activation_email?: boolean;
  can_change_trust_level?: boolean;
  can_view_action_logs?: boolean;
  can_disable_second_factor?: boolean;
  groups?: Array<{ id: number; name: string; automatic?: boolean }>;
  // discourse-user-notes, when it's on.
  user_notes_count?: number;
  // This plugin's per-user slow mode.
  mod_slow_mode?: { seconds: number; ends_at: string | null } | null;
  can_set_mod_slow_mode?: boolean;
}

export interface UserStaffHooks {
  // Re-show the profile, after a change.
  reload: (message: string) => void;
  // The account is gone (deleted, merged, anonymized).
  gone: (message: string) => void;
}

const LEVELS = ["New user", "Basic", "Member", "Regular", "Leader"];

const SLOW_MODE: Choice[] = [
  { label: "10 minutes", value: "600" },
  { label: "15 minutes", value: "900" },
  { label: "30 minutes", value: "1800" },
  { label: "1 hour", value: "3600" },
  { label: "4 hours", value: "14400" },
  { label: "12 hours", value: "43200" },
  { label: "24 hours", value: "86400" },
];

function future(at: string | null | undefined): boolean {
  return !!at && new Date(at).getTime() > Date.now();
}

function summary(a: AdminUser): string {
  const parts: string[] = [];
  parts.push(
    a.admin
      ? "Admin"
      : a.moderator
        ? "Moderator"
        : "Trust level " +
          a.trust_level +
          (a.manual_locked_trust_level !== null &&
          a.manual_locked_trust_level !== undefined
            ? " (locked)"
            : "")
  );
  if (future(a.suspended_till))
    parts.push("suspended until " + longDate(a.suspended_till as string));
  if (future(a.silenced_till))
    parts.push("silenced until " + longDate(a.silenced_till as string));
  if (a.mod_slow_mode) parts.push("in slow mode");
  if (!a.active) parts.push("not activated");
  if (a.approved === false) parts.push("not approved");
  return parts.join(" · ");
}

export function userStaffMenu(
  target: { id: number; username: string },
  hooks: UserStaffHooks
): void {
  if (!isStaffUser()) return;
  get<AdminUser>(`/admin/users/${target.id}.json`).then(
    (a) => paintMenu(a, hooks),
    fail
  );
}

function paintMenu(a: AdminUser, hooks: UserStaffHooks): void {
  const base = `/admin/users/${a.id}`;
  const did = (message: string) => () => hooks.reload(message);
  const items: SheetItem[] = [];
  const staffTarget = a.admin || a.moderator;

  // ── Penalties ───────────────────────────────────────────────────────
  if (future(a.suspended_till))
    items.push({
      label: "Unsuspend",
      icon: "unlock",
      hint: a.full_suspend_reason
        ? truncate(a.full_suspend_reason, 30)
        : undefined,
      run: () => put(`${base}/unsuspend.json`).then(did("Unsuspended."), fail),
    });
  else if (a.can_be_suspended !== false && !staffTarget)
    items.push({
      label: "Suspend…",
      icon: "lock",
      danger: true,
      run: () =>
        penalty("Suspend", (until, reason, message) =>
          put(`${base}/suspend.json`, {
            suspend_until: until.toISOString(),
            reason,
            message,
          }).then(did("Suspended."), fail)
        ),
    });

  if (future(a.silenced_till))
    items.push({
      label: "Unsilence",
      icon: "unlock",
      hint: a.full_silence_reason
        ? truncate(a.full_silence_reason, 30)
        : undefined,
      run: () => put(`${base}/unsilence.json`).then(did("Unsilenced."), fail),
    });
  else if (!staffTarget)
    items.push({
      label: "Silence…",
      icon: "mute",
      danger: true,
      run: () =>
        penalty("Silence", (until, reason, message) =>
          put(`${base}/silence.json`, {
            silenced_till: until.toISOString(),
            reason,
            message,
          }).then(did("Silenced."), fail)
        ),
    });

  if (a.can_set_mod_slow_mode)
    items.push(
      a.mod_slow_mode
        ? {
            label: "End slow mode",
            icon: "clock",
            hint:
              "every " +
              Math.round(a.mod_slow_mode.seconds / 60) +
              " min" +
              (a.mod_slow_mode.ends_at
                ? ", until " + dateTime(a.mod_slow_mode.ends_at)
                : ""),
            run: () =>
              del(`/discourse-mod-categories/user/${a.id}/slow-mode.json`).then(
                did("Slow mode ended."),
                fail
              ),
          }
        : {
            label: "Slow mode…",
            icon: "clock",
            run: () => slowMode(a, hooks),
          }
    );

  if (!staffTarget)
    items.push({
      label: "Send official warning…",
      icon: "flag",
      run: () =>
        openComposer({ kind: "message", to: a.username, warning: true }),
    });

  // ── Trust level and roles ───────────────────────────────────────────
  if (a.can_change_trust_level)
    items.push({
      label: "Trust level…",
      icon: "award",
      hint: LEVELS[a.trust_level] || String(a.trust_level),
      run: () =>
        choose(
          "Trust level",
          LEVELS.map((name, i) => ({
            label: i + " · " + name,
            value: String(i),
            active: i === a.trust_level,
          })),
          (level) =>
            put(`${base}/trust_level.json`, {
              level: parseInt(level, 10),
            }).then(did("Trust level changed."), fail)
        ),
    });
  if (a.can_change_trust_level || isAdminUser()) {
    const locked =
      a.manual_locked_trust_level !== null &&
      a.manual_locked_trust_level !== undefined;
    items.push({
      label: locked ? "Unlock trust level" : "Lock trust level",
      icon: locked ? "unlock" : "lock",
      hint: locked ? undefined : "Stops it changing by itself",
      run: () =>
        put(`${base}/trust_level_lock.json`, { locked: !locked }).then(
          did(locked ? "Trust level unlocked." : "Trust level locked."),
          fail
        ),
    });
  }
  if (a.can_grant_moderation)
    items.push({
      label: "Make moderator",
      icon: "shield",
      run: () =>
        confirmDialog(`Make @${a.username} a moderator?`, {
          ok: "Make moderator",
        }).then((ok) => {
          if (ok)
            put(`${base}/grant_moderation.json`).then(
              did("Now a moderator."),
              fail
            );
        }),
    });
  if (a.can_revoke_moderation)
    items.push({
      label: "Remove moderator",
      icon: "shield",
      danger: true,
      run: () =>
        put(`${base}/revoke_moderation.json`).then(
          did("No longer a moderator."),
          fail
        ),
    });
  if (a.can_grant_admin)
    items.push({
      label: "Make admin",
      icon: "shield",
      run: () =>
        confirmDialog(`Make @${a.username} an admin?`, {
          ok: "Make admin",
        }).then((ok) => {
          if (ok)
            put<{ email_confirmation_required?: boolean }>(
              `${base}/grant_admin.json`
            ).then((r) => {
              if (r && r.email_confirmation_required)
                void alertDialog(
                  "Check your email: confirming there finishes it.",
                  "Make admin"
                );
              else hooks.reload("Now an admin.");
            }, fail);
        }),
    });
  if (a.can_revoke_admin)
    items.push({
      label: "Remove admin",
      icon: "shield",
      danger: true,
      run: () =>
        put(`${base}/revoke_admin.json`).then(did("No longer an admin."), fail),
    });

  // ── Account ─────────────────────────────────────────────────────────
  if (a.can_approve && a.approved === false)
    items.push({
      label: "Approve",
      icon: "check",
      run: () => put(`${base}/approve.json`).then(did("Approved."), fail),
    });
  if (a.can_activate && !a.active)
    items.push({
      label: "Activate",
      icon: "check",
      run: () => put(`${base}/activate.json`).then(did("Activated."), fail),
    });
  if (a.can_send_activation_email && !a.active)
    items.push({
      label: "Send activation email",
      icon: "mail",
      run: () =>
        apiPost("/u/action/send_activation_email.json", {
          username: a.username,
        }).then(() => toast("Activation email sent.", "success"), fail),
    });
  if (a.can_deactivate && a.active)
    items.push({
      label: "Deactivate",
      icon: "lock",
      run: () => put(`${base}/deactivate.json`).then(did("Deactivated."), fail),
    });

  if ("user_notes_count" in a)
    items.push({
      label: "Staff notes",
      icon: "draft",
      hint: String(a.user_notes_count || 0),
      run: () => userNotes(a),
    });

  if (settings.staff && settings.staff.badgesEnabled)
    items.push({
      label: "Grant badge…",
      icon: "award",
      run: () => grantBadgeTo(a.username),
    });

  if (isAdminUser())
    items.push({
      label: "Groups…",
      icon: "users",
      hint: String((a.groups || []).filter((g) => !g.automatic).length || ""),
      run: () => groupsMenu(a, hooks),
    });

  if (a.ip_address || a.registration_ip_address)
    items.push({
      label: "IP addresses…",
      icon: "globe",
      hint: a.ip_address || undefined,
      run: () => ipMenu(a),
    });

  if (a.can_view_action_logs)
    items.push({
      label: "Staff actions on them",
      icon: "list",
      run: () => staffLogs(a.username),
    });

  if (a.can_impersonate)
    items.push({
      label: "Impersonate",
      icon: "user",
      run: () =>
        confirmDialog(
          `Use the forum as @${a.username}? Log out to come back as yourself.`,
          { ok: "Impersonate" }
        ).then((ok) => {
          if (ok)
            apiPost("/admin/impersonate.json", {
              username_or_email: a.username,
            }).then(() => {
              location.href = settings.subfolder + settings.basePath + "/";
            }, fail);
        }),
    });

  if (isAdminUser())
    items.push({
      label: "Log out everywhere",
      icon: "logout",
      run: () =>
        apiPost(`${base}/log_out.json`).then(
          () => toast("Logged out everywhere.", "success"),
          fail
        ),
    });

  if (a.can_disable_second_factor && a.second_factor_enabled)
    items.push({
      label: "Turn off two-factor sign-in",
      icon: "key",
      danger: true,
      run: () =>
        confirmDialog(`Turn off two-factor sign-in for @${a.username}?`, {
          ok: "Turn off",
          danger: true,
        }).then((ok) => {
          if (ok)
            put(`${base}/disable_second_factor.json`).then(
              did("Two-factor sign-in turned off."),
              fail
            );
        }),
    });

  // ── The end of the account ──────────────────────────────────────────
  if (a.can_delete_all_posts && (a.post_count || 0) > 0)
    items.push({
      label: "Delete all posts…",
      icon: "trash",
      danger: true,
      run: () => deleteAllPosts(a, hooks),
    });
  if (a.can_be_merged && isAdminUser())
    items.push({
      label: "Merge into another account…",
      icon: "users",
      danger: true,
      run: () =>
        askUsername("Merge into", (into) =>
          confirmDialog(
            `Move everything of @${a.username} to @${into} and delete @${a.username}?`,
            { ok: "Merge", danger: true }
          ).then((ok) => {
            if (ok)
              apiPost(`${base}/merge.json`, { target_username: into }).then(
                () => hooks.gone("Merging. It finishes in a moment."),
                fail
              );
          })
        ),
    });
  if (a.can_be_anonymized)
    items.push({
      label: "Anonymize",
      icon: "user",
      danger: true,
      run: () =>
        confirmDialog(
          `Anonymize @${a.username}? Their name, email and profile are wiped; their posts stay.`,
          { ok: "Anonymize", danger: true }
        ).then((ok) => {
          if (ok)
            put(`${base}/anonymize.json`).then(
              () => hooks.gone("Anonymized."),
              fail
            );
        }),
    });
  if (a.can_be_deleted)
    items.push({
      label: "Delete account…",
      icon: "trash",
      danger: true,
      run: () => deleteUser(a, hooks),
    });

  actionSheet("@" + a.username, items, { subtitle: summary(a) });
}

// Until when, why (for the logs and the email), and what to tell them.
function penalty(
  what: string,
  done: (until: Date, reason: string, message: string) => void
): void {
  chooseUntil(what + " until", (until) =>
    askText(what, "Why (the member sees this)", (reason) =>
      askText(
        what,
        "A message to email them (optional)",
        (message) => done(until, reason, message),
        { optional: true, ok: what }
      )
    )
  );
}

function slowMode(a: AdminUser, hooks: UserStaffHooks): void {
  choose(
    "Slow mode for @" + a.username,
    SLOW_MODE.map((c) => ({
      label: "One post every " + c.label,
      value: c.value,
    })),
    (seconds) => {
      const send = (endsAt: Date | null) =>
        askText("Slow mode", "Why (they're told)", (reason) =>
          put(`/discourse-mod-categories/user/${a.id}/slow-mode.json`, {
            seconds: parseInt(seconds, 10),
            ends_at: endsAt ? endsAt.toISOString() : "",
            reason,
          }).then(() => hooks.reload("Slow mode on."), fail)
        );
      choose(
        "Slow mode for",
        [
          { label: "1 day", value: String(DAY) },
          { label: "1 week", value: String(7 * DAY) },
          { label: "1 month", value: String(30 * DAY) },
          { label: "No end", value: "never" },
          { label: "Pick a date…", value: "pick" },
        ],
        (end) => {
          if (end === "never") send(null);
          else if (end === "pick") askDate("Slow mode until", send);
          else send(new Date(Date.now() + parseInt(end, 10)));
        }
      );
    }
  );
}

interface UserNote {
  id: string;
  raw: string;
  created_at: string;
  created_by?: { username: string } | null;
  can_delete?: boolean;
}

function userNotes(a: AdminUser): void {
  get<{ user_notes?: UserNote[] }>(`/user_notes?user_id=${a.id}`).then((d) => {
    const notes = d.user_notes || [];
    const items: SheetItem[] = [
      {
        label: "Add a note…",
        icon: "plus",
        run: () =>
          askText("Staff note on @" + a.username, "Only staff see it", (raw) =>
            apiPost("/user_notes", {
              user_note: { user_id: a.id, raw },
            }).then(() => {
              toast("Note added.", "success");
              userNotes(a);
            }, fail)
          ),
      },
    ];
    notes.forEach((n) =>
      items.push({
        label: truncate(n.raw, 60),
        hint:
          (n.created_by ? "@" + n.created_by.username + ", " : "") +
          timeAgo(n.created_at),
        run: () => {
          const list: SheetItem[] = [
            {
              label: "Read it",
              icon: "eye",
              run: () => void alertDialog(n.raw, "Staff note"),
            },
          ];
          if (n.can_delete)
            list.push({
              label: "Delete it",
              icon: "trash",
              danger: true,
              run: () =>
                confirmDialog("Delete this note?", {
                  ok: "Delete",
                  danger: true,
                }).then((ok) => {
                  if (ok)
                    del(`/user_notes/${n.id}?user_id=${a.id}`).then(() => {
                      toast("Note deleted.", "success");
                      userNotes(a);
                    }, fail);
                }),
            });
          actionSheet("Staff note", list, { subtitle: truncate(n.raw, 80) });
        },
      })
    );
    actionSheet("Staff notes on @" + a.username, items, {
      subtitle: notes.length ? undefined : "No notes yet.",
    });
  }, fail);
}

function groupsMenu(a: AdminUser, hooks: UserStaffHooks): void {
  const base = `/admin/users/${a.id}`;
  const items: SheetItem[] = [
    {
      label: "Add to a group…",
      icon: "plus",
      run: () =>
        askUsername(
          "Add to a group",
          (name) =>
            get<{ group?: { id: number } }>(
              `/groups/${encodeURIComponent(name)}.json`
            ).then((d) => {
              if (!d.group) return;
              apiPost(`${base}/groups.json`, { group_id: d.group.id }).then(
                () => hooks.reload("Added to " + name + "."),
                fail
              );
            }, fail),
          "Group name"
        ),
    },
  ];
  (a.groups || [])
    .filter((g) => !g.automatic)
    .forEach((g) =>
      items.push({
        label: "Remove from " + g.name,
        icon: "x",
        run: () =>
          del(`${base}/groups/${g.id}.json`).then(
            () => hooks.reload("Removed from " + g.name + "."),
            fail
          ),
      })
    );
  actionSheet("Groups", items);
}

interface IpInfo {
  hostname?: string;
  location?: string;
  organization?: string;
  city?: string;
  region?: string;
  country?: string;
}

function ipMenu(a: AdminUser): void {
  const items: SheetItem[] = [];
  const add = (label: string, ip?: string) => {
    if (!ip) return;
    items.push({ label: label + ": " + ip, heading: true });
    items.push({
      label: "Where it is",
      icon: "globe",
      run: () =>
        get<IpInfo>(
          `/admin/users/ip-info.json?ip=${encodeURIComponent(ip)}`
        ).then((info) => {
          const lines = [
            info.location ||
              [info.city, info.region, info.country]
                .filter((x) => !!x)
                .join(", "),
            info.organization,
            info.hostname,
          ].filter((x) => !!x);
          void alertDialog(lines.join("\n") || "Nothing known.", ip);
        }, fail),
    });
    items.push({
      label: "Other accounts on it",
      icon: "users",
      run: () =>
        get<Array<{ username: string; last_seen_at?: string | null }>>(
          `/admin/users/list/active.json?ip=${encodeURIComponent(ip)}&exclude=${a.id}`
        ).then((list) => {
          if (!list || !list.length) {
            toast("No other accounts.");
            return;
          }
          actionSheet(
            "Accounts on " + ip,
            list.map((u) => ({
              label: "@" + u.username,
              icon: "user",
              hint: u.last_seen_at ? timeAgo(u.last_seen_at) : undefined,
              href: href(userPath(u.username)),
            }))
          );
        }, fail),
    });
  };
  add("Last used", a.ip_address);
  if (a.registration_ip_address !== a.ip_address)
    add("Signed up from", a.registration_ip_address);
  actionSheet("IP addresses", items);
}

interface StaffLog {
  action_name: string;
  details?: string | null;
  created_at: string;
  acting_user?: { username: string } | null;
}

function staffLogs(username: string): void {
  get<{ staff_action_logs?: StaffLog[] }>(
    `/admin/logs/staff_action_logs.json?target_user=${encodeURIComponent(username)}`
  ).then((d) => {
    const logs = d.staff_action_logs || [];
    if (!logs.length) {
      toast("No staff actions on them.");
      return;
    }
    actionSheet(
      "Staff actions on @" + username,
      logs.slice(0, 50).map((l) => ({
        label: l.action_name.replace(/_/g, " "),
        hint:
          (l.acting_user ? "@" + l.acting_user.username + ", " : "") +
          timeAgo(l.created_at),
        run: () =>
          void alertDialog(
            (l.details || "No details.") +
              "\n\n" +
              (l.acting_user ? "By @" + l.acting_user.username + ", " : "") +
              dateTime(l.created_at),
            l.action_name.replace(/_/g, " ")
          ),
      }))
    );
  }, fail);
}

function deleteAllPosts(a: AdminUser, hooks: UserStaffHooks): void {
  confirmDialog(
    `Delete all ${a.post_count} posts by @${a.username}? It can't be undone here.`,
    { ok: "Delete all", danger: true }
  ).then((ok) => {
    if (!ok) return;
    let total = 0;
    const batch = (): Promise<void> =>
      put<{ posts_deleted: number }>(
        `/admin/users/${a.id}/delete_posts_batch.json`
      ).then((r) => {
        const n = (r && r.posts_deleted) || 0;
        total += n;
        if (n > 0) {
          toast(`Deleted ${total} so far…`);
          return batch();
        }
        hooks.reload(`Deleted ${total} posts.`);
        return undefined;
      });
    batch().catch(fail);
  });
}

function deleteUser(a: AdminUser, hooks: UserStaffHooks): void {
  choose(
    "Delete @" + a.username,
    [
      {
        label: "Delete the account and its posts",
        value: "delete",
        danger: true,
      },
      {
        label: "Delete as a spammer (and block their email and IP)",
        value: "spammer",
        danger: true,
      },
    ],
    (how) =>
      confirmDialog(
        how === "spammer"
          ? `Delete @${a.username} as a spammer? Their posts go, and their email and IP are blocked.`
          : `Delete @${a.username} and their posts?`,
        { ok: "Delete", danger: true }
      ).then((ok) => {
        if (!ok) return;
        const spammer = how === "spammer";
        del<{ deleted?: boolean }>(`/admin/users/${a.id}.json`, {
          delete_posts: true,
          block_email: spammer,
          block_urls: spammer,
          block_ip: spammer,
          delete_as_spammer: spammer,
        }).then((r) => {
          if (r && r.deleted === false)
            toast("The forum couldn't delete that account.", "error");
          else hooks.gone("Account deleted.");
        }, fail);
      })
  );
}

// Whether staff see the profile's Moderate button for this member.
export function canModerateUser(target: { username: string }): boolean {
  return isStaffUser() && !!user && user.username !== target.username;
}
