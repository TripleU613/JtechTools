// Pieces the staff menus share: who may do what, and the pickers they use
// (a time, a length of time, a category, a topic, a user) as key-driven
// sheets and prompts.

import { errorMessage, get } from "../api.ts";
import { user } from "../session.ts";
import { allCategories, categoryName } from "../site.ts";
import {
  actionSheet,
  promptDialog,
  type SheetItem,
  toast,
} from "../ui/layers.ts";
import { decodeEntities } from "../ui/topic-row.ts";
import { parseLocalDateTime, topicIdFrom } from "../staff-logic.ts";

export { parseLocalDateTime, topicIdFrom };

export interface Choice {
  label: string;
  value: string;
  hint?: string;
  active?: boolean;
  danger?: boolean;
}

export const HOUR = 3600 * 1000;
export const DAY = 24 * HOUR;

export function fail(e: unknown): void {
  toast(errorMessage(e), "error");
}

// Staff, or a trust level 4 leader: who core's menus show the topic
// management items to (User#canManageTopic).
export function canManageTopic(): boolean {
  return !!user && (user.admin || user.moderator || user.trust_level >= 4);
}

export function isStaffUser(): boolean {
  return !!user && (user.admin || user.moderator);
}

export function isAdminUser(): boolean {
  return !!user && user.admin;
}

export function choose(
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
        danger: c.danger,
        run: () => pick(c.value),
      })
    ),
    subtitle ? { subtitle } : {}
  );
}

function pad(n: number): string {
  return (n < 10 ? "0" : "") + n;
}

export function localValue(d: Date): string {
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

// Asks for a date and time; in the future unless `past` is allowed.
export function askDate(
  title: string,
  done: (d: Date) => void,
  value?: Date,
  past?: boolean
): void {
  promptDialog("Date and time (YYYY-MM-DD HH:MM)", {
    title,
    value: localValue(value || new Date(Date.now() + DAY)),
    ok: "Set",
  }).then((v) => {
    if (v === null) return;
    const d = parseLocalDateTime(v);
    if (!d) toast("Write it as 2026-11-05 14:30.", "error");
    else if (!past && d.getTime() <= Date.now())
      toast("Pick a time in the future.", "error");
    else done(d);
  });
}

// When something should happen: a few common times, or a date.
export function chooseWhen(title: string, done: (d: Date) => void): void {
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
export function chooseDuration(
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

// Until when, for a penalty: a few lengths, forever, or a date.
export function chooseUntil(title: string, done: (d: Date) => void): void {
  const at = (ms: number) => String(Date.now() + ms);
  choose(
    title,
    [
      { label: "1 day", value: at(DAY) },
      { label: "3 days", value: at(3 * DAY) },
      { label: "1 week", value: at(7 * DAY) },
      { label: "2 weeks", value: at(14 * DAY) },
      { label: "1 month", value: at(30 * DAY) },
      { label: "3 months", value: at(91 * DAY) },
      { label: "1 year", value: at(365 * DAY) },
      { label: "Forever", value: "forever" },
      { label: "Pick a date…", value: "pick" },
    ],
    (v) => {
      if (v === "pick") askDate(title, done);
      // What core's "forever" sends: 1000 years from now.
      else if (v === "forever") done(new Date(Date.now() + 365000 * DAY));
      else done(new Date(parseInt(v, 10)));
    }
  );
}

export function chooseCategory(
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

interface FoundTopic {
  id: number;
  title: string;
  fancy_title?: string;
  archetype?: string;
}

// A topic, by link, number or a search for its title. `messages` searches
// the messages the person can see instead.
export function chooseTopic(
  title: string,
  done: (id: number) => void,
  opts: { messages?: boolean; exclude?: number } = {}
): void {
  promptDialog("Search, or paste a link or topic number", {
    title,
    ok: "Find",
  }).then((v) => {
    if (v === null || !v.replace(/\s+/g, "")) return;
    const id = topicIdFrom(v);
    if (id) {
      if (id === opts.exclude) toast("That's this topic.", "error");
      else done(id);
      return;
    }
    const q =
      v + (opts.messages ? " in:messages" : "") + " status:open order:latest";
    get<{ topics?: FoundTopic[] }>(
      "/search/query.json?term=" + encodeURIComponent(q) + "&type_filter=topic"
    ).then((d) => {
      const found = (d.topics || []).filter((t) => t.id !== opts.exclude);
      if (!found.length) {
        toast("No topics found.", "error");
        return;
      }
      choose(
        title,
        found.slice(0, 20).map((t) => ({
          label: decodeEntities(t.fancy_title || t.title),
          value: String(t.id),
          hint: "#" + t.id,
        })),
        (picked) => done(parseInt(picked, 10))
      );
    }, fail);
  });
}

// A username, typed (the @ is optional).
export function askUsername(
  title: string,
  done: (username: string) => void,
  label = "Username"
): void {
  promptDialog(label, { title, ok: "OK" }).then((v) => {
    const name = (v || "").replace(/^[\s@]+|\s+$/g, "");
    if (name) done(name);
  });
}

// A reason or message, required unless `optional`.
export function askText(
  title: string,
  label: string,
  done: (text: string) => void,
  opts: { optional?: boolean; value?: string; ok?: string } = {}
): void {
  promptDialog(label, {
    title,
    multiline: true,
    value: opts.value,
    ok: opts.ok || "OK",
  }).then((v) => {
    if (v === null) return;
    const text = v.replace(/^\s+|\s+$/g, "");
    if (!text && !opts.optional) {
      toast("Write something first.", "error");
      return;
    }
    done(text);
  });
}
