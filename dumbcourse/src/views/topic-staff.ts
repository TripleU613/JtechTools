// The staff side of a topic's Options menu: everything core's topic admin
// menu (the wrench) offers, as key-driven sheets and prompts. Each item shows
// under core's own condition for it (topic-admin-menu.gjs), and each action
// calls the endpoint core's menu calls, so the server's checks are the same.

import { del, errorMessage, post as apiPost, put } from "../api.ts";
import { dateTime, parseDate } from "../format.ts";
import { user } from "../session.ts";
import { allCategories, categoryName } from "../site.ts";
import type { Topic } from "../types.ts";
import {
  actionSheet,
  confirmDialog,
  promptDialog,
  type SheetItem,
  toast,
} from "../ui/layers.ts";

// What the topic screen does after a change: reload it, or leave it.
export interface TopicStaffHooks {
  reload: (message: string) => void;
  gone: (message: string) => void;
}

interface Choice {
  label: string;
  value: string;
  hint?: string;
  active?: boolean;
}

const HOUR = 3600 * 1000;
const DAY = 24 * HOUR;

// Staff, or a trust level 4 leader: who core's menu shows the topic
// management items to (User#canManageTopic).
function canManageTopic(): boolean {
  return !!user && (user.admin || user.moderator || user.trust_level >= 4);
}

function isStaffUser(): boolean {
  return !!user && (user.admin || user.moderator);
}

function isPrivateMessage(t: Topic): boolean {
  return t.archetype === "private_message";
}

function choose(
  title: string,
  choices: Choice[],
  pick: (value: string) => void,
  subtitle?: string
): void {
  actionSheet(
    title,
    choices.map(
      (c): SheetItem => ({
        label: c.label,
        hint: c.hint,
        active: c.active,
        run: () => pick(c.value),
      })
    ),
    subtitle ? { subtitle } : {}
  );
}

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

function pad(n: number): string {
  return (n < 10 ? "0" : "") + n;
}

function localValue(d: Date): string {
  return (
    d.getFullYear() +
    "-" +
    pad(d.getMonth() + 1) +
    "-" +
    pad(d.getDate()) +
    " " +
    pad(d.getHours()) +
    ":" +
    pad(d.getMinutes())
  );
}

// Asks for a date and time in the future.
function askDate(title: string, done: (d: Date) => void, value?: Date): void {
  promptDialog("Date and time (YYYY-MM-DD HH:MM)", {
    title,
    value: localValue(value || new Date(Date.now() + DAY)),
    ok: "Set",
  }).then((v) => {
    if (v === null) return;
    const d = parseLocalDateTime(v);
    if (!d) toast("Write it as 2026-11-05 14:30.", "error");
    else if (d.getTime() <= Date.now())
      toast("Pick a time in the future.", "error");
    else done(d);
  });
}

// When something should happen: a few common times, or a date.
function chooseWhen(title: string, done: (d: Date) => void): void {
  const at = (ms: number) => String(Date.now() + ms);
  choose(
    title,
    [
      { label: "In 1 hour", value: at(HOUR) },
      { label: "In 4 hours", value: at(4 * HOUR) },
      { label: "In 1 day", value: at(DAY) },
      { label: "In 3 days", value: at(3 * DAY) },
      { label: "In 1 week", value: at(7 * DAY) },
      { label: "In 1 month", value: at(30 * DAY) },
      { label: "Pick a date…", value: "pick" },
    ],
    (v) => {
      if (v === "pick") askDate(title, done);
      else done(new Date(parseInt(v, 10)));
    }
  );
}

// How long, in minutes.
function chooseDuration(
  title: string,
  unit: "hours" | "days",
  done: (minutes: number) => void
): void {
  const choices: Choice[] =
    unit === "hours"
      ? [
          { label: "1 hour", value: "60" },
          { label: "4 hours", value: "240" },
          { label: "12 hours", value: "720" },
          { label: "1 day", value: "1440" },
          { label: "3 days", value: "4320" },
          { label: "1 week", value: "10080" },
          { label: "1 month", value: "43200" },
          { label: "Other…", value: "other" },
        ]
      : [
          { label: "1 day", value: "1440" },
          { label: "3 days", value: "4320" },
          { label: "1 week", value: "10080" },
          { label: "2 weeks", value: "20160" },
          { label: "1 month", value: "43200" },
          { label: "Other…", value: "other" },
        ];
  choose(title, choices, (v) => {
    if (v !== "other") {
      done(parseInt(v, 10));
      return;
    }
    promptDialog(unit === "hours" ? "Hours" : "Days", {
      title,
      type: "number",
      ok: "Set",
    }).then((n) => {
      const num = parseFloat(n || "");
      if (!(num > 0)) return;
      done(Math.round(num * (unit === "hours" ? 60 : 1440)));
    });
  });
}

function chooseCategory(
  title: string,
  done: (id: number) => void,
  current?: number | null
): void {
  const cats = allCategories();
  if (!cats.length) {
    toast("No categories to choose from.", "error");
    return;
  }
  choose(
    title,
    cats.map((c) => ({
      label: categoryName(c),
      value: String(c.id),
      active: c.id === current,
    })),
    (v) => done(parseInt(v, 10))
  );
}

const TIMER_NAMES: Record<string, string> = {
  close: "closes",
  open: "opens",
  publish_to_category: "is published",
  delete: "is deleted",
  bump: "is bumped",
  delete_replies: "deletes replies",
};

// "Closes Nov 5, 2026 2:30 PM", for the timer sheet's subtitle.
export function timerSummary(t: Topic): string {
  const timer = t.topic_timer;
  if (!timer) return "";
  const what = TIMER_NAMES[timer.status_type] || timer.status_type;
  if (timer.status_type === "delete_replies" && timer.duration_minutes)
    return `Deletes replies older than ${Math.round(timer.duration_minutes / 1440)} days`;
  if (timer.based_on_last_post && timer.duration_minutes)
    return (
      what.charAt(0).toUpperCase() +
      what.slice(1) +
      ` ${Math.round(timer.duration_minutes / 60)} hours after the last reply`
    );
  const at = parseDate(timer.execute_at);
  return at
    ? what.charAt(0).toUpperCase() + what.slice(1) + " " + dateTime(at)
    : "";
}

const SLOW_MODE_CHOICES: Choice[] = [
  { label: "10 minutes", value: "600" },
  { label: "15 minutes", value: "900" },
  { label: "30 minutes", value: "1800" },
  { label: "45 minutes", value: "2700" },
  { label: "1 hour", value: "3600" },
  { label: "2 hours", value: "7200" },
  { label: "4 hours", value: "14400" },
  { label: "8 hours", value: "28800" },
  { label: "12 hours", value: "43200" },
  { label: "24 hours", value: "86400" },
];

export function topicStaffItems(t: Topic, hooks: TopicStaffHooks): SheetItem[] {
  const d = t.details || {};
  const pm = isPrivateMessage(t);
  const items: SheetItem[] = [];

  const fail = (e: unknown) => toast(errorMessage(e), "error");

  const status = (
    name: string,
    enabled: boolean,
    message: string,
    until?: Date | null
  ) => {
    const body: Record<string, unknown> = {
      status: name,
      enabled: enabled ? "true" : "false",
    };
    if (until !== undefined) body.until = until ? until.toISOString() : "";
    put(`/t/${t.id}/status.json`, body).then(() => hooks.reload(message), fail);
  };

  // ── Delete, restore, delete permanently ─────────────────────────────
  if (t.deleted_at && d.can_recover)
    items.push({
      label: "Restore topic",
      icon: "undo",
      run: () =>
        put(`/t/${t.id}/recover.json`).then(
          () => hooks.reload("Topic restored."),
          fail
        ),
    });
  else if (d.can_delete)
    items.push({
      label: "Delete topic",
      icon: "trash",
      danger: true,
      run: () =>
        confirmDialog("Delete this whole topic?", {
          ok: "Delete",
          danger: true,
        }).then((ok) => {
          if (ok)
            del(`/t/${t.id}.json`).then(
              () => hooks.gone("Topic deleted."),
              fail
            );
        }),
    });
  if (t.deleted_at && d.can_permanently_delete)
    items.push({
      label: "Delete permanently",
      icon: "trash",
      danger: true,
      run: () =>
        confirmDialog(
          "Delete this topic permanently? It can't be restored afterwards.",
          { ok: "Delete permanently", danger: true }
        ).then((ok) => {
          if (ok)
            del(`/t/${t.id}.json`, { force_destroy: "true" }).then(
              () => hooks.gone("Topic deleted permanently."),
              fail
            );
        }),
    });

  // ── Close, pin, banner, archive, visibility, convert ────────────────
  if (d.can_close_topic)
    items.push({
      label: t.closed ? "Open topic" : "Close topic",
      icon: t.closed ? "unlock" : "lock",
      run: () =>
        status(
          "closed",
          !t.closed,
          t.closed ? "Topic opened." : "Topic closed."
        ),
    });

  if (d.can_pin_unpin_topic && t.pinned)
    items.push({
      label: t.pinned_globally ? "Unpin (pinned globally)" : "Unpin",
      icon: "pin",
      hint: t.pinned_until ? "until " + dateTime(t.pinned_until) : undefined,
      run: () =>
        status(
          t.pinned_globally ? "pinned_globally" : "pinned",
          false,
          "Unpinned."
        ),
    });
  else if (d.can_pin_unpin_topic && t.visible !== false && !pm)
    items.push({
      label: "Pin…",
      icon: "pin",
      run: () =>
        choose("Pin topic", pinChoices(t), (where) =>
          choose(
            where === "pinned_globally" ? "Pin globally until" : "Pin until",
            [
              { label: "1 day", value: String(DAY) },
              { label: "1 week", value: String(7 * DAY) },
              { label: "2 weeks", value: String(14 * DAY) },
              { label: "1 month", value: String(30 * DAY) },
              { label: "No end", value: "never" },
              { label: "Pick a date…", value: "pick" },
            ],
            (v) => {
              if (v === "never") status(where, true, "Pinned.", null);
              else if (v === "pick")
                askDate("Pin until", (until) =>
                  status(where, true, "Pinned.", until)
                );
              else
                status(
                  where,
                  true,
                  "Pinned.",
                  new Date(Date.now() + parseInt(v, 10))
                );
            }
          )
        ),
    });

  if (d.can_banner_topic && !pm)
    items.push(
      t.archetype === "banner"
        ? {
            label: "Remove banner",
            icon: "flag",
            run: () =>
              put(`/t/${t.id}/remove-banner.json`).then(
                () => hooks.reload("Banner removed."),
                fail
              ),
          }
        : {
            label: "Make banner",
            icon: "flag",
            run: () =>
              confirmDialog(
                "Show this topic as a banner at the top of every page, for everyone?",
                { ok: "Make banner" }
              ).then((ok) => {
                if (ok)
                  put(`/t/${t.id}/make-banner.json`).then(
                    () => hooks.reload("Made banner."),
                    fail
                  );
              }),
          }
    );

  if (d.can_archive_topic && !pm)
    items.push({
      label: t.archived ? "Unarchive" : "Archive",
      icon: "archive",
      run: () =>
        status(
          "archived",
          !t.archived,
          t.archived ? "Topic unarchived." : "Topic archived."
        ),
    });

  if (d.can_toggle_topic_visibility)
    items.push({
      label: t.visible === false ? "List topic" : "Unlist topic",
      icon: "hide",
      run: () =>
        status(
          "visible",
          t.visible === false,
          t.visible === false ? "Topic listed." : "Topic unlisted."
        ),
    });

  if (d.can_convert_topic)
    items.push(
      pm
        ? {
            label: "Make public topic",
            icon: "chat",
            run: () =>
              chooseCategory("Into which category?", (categoryId) =>
                put(`/t/${t.id}/convert-topic/public.json`, {
                  category_id: categoryId,
                }).then(() => hooks.reload("Now a public topic."), fail)
              ),
          }
        : {
            label: "Make private message",
            icon: "mail",
            run: () =>
              confirmDialog(
                "Turn this topic into a private message? Only its participants and staff will see it.",
                { ok: "Convert" }
              ).then((ok) => {
                if (ok)
                  put(`/t/${t.id}/convert-topic/private.json`).then(
                    () => hooks.reload("Now a private message."),
                    fail
                  );
              }),
          }
    );

  // ── Topic management: timer, timestamp, bump date, slow mode ────────
  if (canManageTopic()) {
    items.push({
      label: "Set timer…",
      icon: "clock",
      hint: timerSummary(t) || undefined,
      run: () => timerMenu(t, hooks, fail),
    });
    if (isStaffUser())
      items.push({
        label: "Change timestamp…",
        icon: "clock",
        run: () =>
          askDate(
            "Change timestamp",
            (when) =>
              put(`/t/${t.id}/change-timestamp.json`, {
                timestamp: Math.floor(when.getTime() / 1000),
              }).then(() => hooks.reload("Timestamp changed."), fail),
            parseDate(t.created_at) || undefined
          ),
      });
    items.push({
      label: "Reset bump date",
      icon: "refresh",
      run: () =>
        put(`/t/${t.id}/reset-bump-date.json`).then(
          () => hooks.reload("Bump date reset."),
          fail
        ),
    });
    items.push({
      label: "Slow mode…",
      icon: "clock",
      hint: t.slow_mode_seconds
        ? slowModeHint(t.slow_mode_seconds, t.slow_mode_enabled_until)
        : undefined,
      run: () => slowModeMenu(t, hooks, fail),
    });
  }

  return items;
}

function pinChoices(t: Topic): Choice[] {
  const choices: Choice[] = [];
  if (t.category_id)
    choices.push({ label: "Pin in its category", value: "pinned" });
  choices.push({ label: "Pin globally", value: "pinned_globally" });
  return choices;
}

function slowModeHint(seconds: number, until?: string | null): string {
  const c = SLOW_MODE_CHOICES.filter((x) => x.value === String(seconds))[0];
  const every = c ? c.label : Math.round(seconds / 60) + " minutes";
  return "every " + every + (until ? ", until " + dateTime(until) : "");
}

function slowModeMenu(
  t: Topic,
  hooks: TopicStaffHooks,
  fail: (e: unknown) => void
): void {
  const send = (seconds: number, until: Date | null, message: string) =>
    put(`/t/${t.id}/slow_mode.json`, {
      seconds,
      enabled_until: until ? until.toISOString() : "",
    }).then(() => hooks.reload(message), fail);

  const choices = SLOW_MODE_CHOICES.map((c) => ({
    label: "One post every " + c.label,
    value: c.value,
    active: String(t.slow_mode_seconds || "") === c.value,
  }));
  if (t.slow_mode_seconds)
    choices.unshift({ label: "Turn off", value: "0", active: false });

  choose(
    "Slow mode",
    choices,
    (v) => {
      const seconds = parseInt(v, 10);
      if (!seconds) {
        send(0, null, "Slow mode off.");
        return;
      }
      choose(
        "Slow mode for",
        [
          { label: "No end", value: "never" },
          { label: "1 day", value: String(DAY) },
          { label: "1 week", value: String(7 * DAY) },
          { label: "Pick a date…", value: "pick" },
        ],
        (end) => {
          if (end === "never") send(seconds, null, "Slow mode on.");
          else if (end === "pick")
            askDate("Slow mode until", (until) =>
              send(seconds, until, "Slow mode on.")
            );
          else
            send(
              seconds,
              new Date(Date.now() + parseInt(end, 10)),
              "Slow mode on."
            );
        }
      );
    },
    t.slow_mode_seconds
      ? "Now: " + slowModeHint(t.slow_mode_seconds, t.slow_mode_enabled_until)
      : undefined
  );
}

// Core's timer types (edit-topic-timer.gjs publicTimerTypes), in its order.
function timerMenu(
  t: Topic,
  hooks: TopicStaffHooks,
  fail: (e: unknown) => void
): void {
  const d = t.details || {};
  const cat = t.category_id
    ? allCategories().filter((c) => c.id === t.category_id)[0]
    : null;

  const send = (body: Record<string, unknown>, message: string) =>
    apiPost(`/t/${t.id}/timer.json`, body).then(
      () => hooks.reload(message),
      fail
    );
  const at = (statusType: string, message: string, title: string) => () =>
    chooseWhen(title, (when) =>
      send({ status_type: statusType, time: when.toISOString() }, message)
    );
  const afterLastPost =
    (statusType: string, message: string, title: string) => () =>
      chooseDuration(title, "hours", (minutes) =>
        send(
          {
            status_type: statusType,
            based_on_last_post: "true",
            duration_minutes: minutes,
          },
          message
        )
      );

  const items: SheetItem[] = [];
  if (!t.closed) {
    items.push({
      label: "Close at a time",
      run: at("close", "Timer set.", "Close the topic"),
    });
    items.push({
      label: "Close after the last reply",
      run: afterLastPost("close", "Timer set.", "Close after no replies for"),
    });
  } else
    items.push({
      label: "Open at a time",
      run: at("open", "Timer set.", "Open the topic"),
    });
  if (d.can_delete) {
    items.push({
      label: "Delete at a time",
      danger: true,
      run: at("delete", "Timer set.", "Delete the topic"),
    });
    items.push({
      label: "Delete after the last reply",
      danger: true,
      run: afterLastPost("delete", "Timer set.", "Delete after no replies for"),
    });
  }
  items.push({
    label: "Bump at a time",
    run: at("bump", "Timer set.", "Bump the topic"),
  });
  if (d.can_delete)
    items.push({
      label: "Delete replies after…",
      danger: true,
      run: () =>
        chooseDuration("Delete replies older than", "days", (minutes) =>
          send(
            { status_type: "delete_replies", duration_minutes: minutes },
            "Timer set."
          )
        ),
    });
  if (t.closed)
    items.push({
      label: "Temporarily open, close again at a time",
      run: at("close", "Timer set.", "Close again"),
    });
  else
    items.push({
      label: "Temporarily close, open again at a time",
      run: at("open", "Timer set.", "Open again"),
    });
  if (
    (cat && cat.read_restricted) ||
    isPrivateMessage(t) ||
    t.visible === false
  )
    items.push({
      label: "Publish to a category at a time",
      run: () =>
        chooseCategory("Publish to which category?", (categoryId) =>
          chooseWhen("Publish", (when) =>
            send(
              {
                status_type: "publish_to_category",
                time: when.toISOString(),
                category_id: categoryId,
              },
              "Timer set."
            )
          )
        ),
    });
  if (t.topic_timer && t.topic_timer.execute_at) {
    const current = t.topic_timer.status_type;
    items.unshift({
      label: "Remove timer",
      icon: "x",
      run: () => send({ status_type: current, time: "" }, "Timer removed."),
    });
  }
  actionSheet("Set timer", items, {
    subtitle: timerSummary(t) || undefined,
  });
}
