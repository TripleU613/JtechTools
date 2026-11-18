import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import Service, { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import JtLineCard from "../components/jt-line.gts";

// The ads for the home page's welcome area (lib/discourse_jtech_ads.rb,
// docs/features/ads.md). They arrive inside the preloaded site data as
// site.jt_lines. Nothing in the browser is named after ads: blockers hide
// elements and requests by names like that.

export interface JtLineCounts {
  up: number;
  down: number;
}

export interface JtLine {
  k: string; // key
  h: string; // headline, cleaned HTML
  t: string; // text, cleaned HTML
  c?: string | null; // the whole card, cleaned HTML of the kit (optional)
  w: number; // weight
  s?: string | null; // starts
  e?: string | null; // ends
  v?: number | null; // this member's thumbs (members only)
  n?: JtLineCounts; // counts (staff only)
}

export interface JtLines {
  label: string;
  every: number; // seconds per line
  intro: number; // seconds of the welcome for a new visitor
  fresh: number; // seconds a logged-out visitor counts as new
  items: JtLine[];
}

// When this browser first came to the site (milliseconds), kept in the
// browser only. Neutral name, like everything here.
const FIRST_SEEN = "jt-l-first";

function firstSeen(): number | null {
  try {
    const stored = Number(window.localStorage.getItem(FIRST_SEEN));
    if (stored > 0) {
      return stored;
    }
    const now = Date.now();
    window.localStorage.setItem(FIRST_SEEN, String(now));
    return now;
  } catch {
    return null;
  }
}

type LinesSite = Site & { jt_lines?: JtLines };

function reducedMotion(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

export default class JtLinesService extends Service {
  @service declare site: LinesSite;
  @service declare currentUser: User | null;

  // The key of the line showing, once rotation has moved on from the first
  @tracked current: string | null = null;
  // The page's renderer got hidden (a blocker's element rule): show the
  // line in the fallback place instead
  @tracked hidden = false;
  @tracked votes: Record<string, number | null> = {};
  @tracked counts: Record<string, JtLineCounts> = {};
  // The welcome's time is up and the ads have slid in
  @tracked introOver = false;

  // A theme that carries the line itself says so at startup (the JTech
  // theme's hero does, when it's on); then the plugin's card stays out.
  // Decided before anything renders, so the two never trade places.
  themeHosted = false;

  // The component that draws one line (the card); a theme renders it too,
  // so a line looks the same wherever it's drawn
  card = JtLineCard;

  #first: string | null = null;
  #introPlanned: boolean | null = null;
  #introTimer: ReturnType<typeof setTimeout> | null = null;

  get data(): JtLines | null {
    return this.site.jt_lines ?? null;
  }

  get label(): string {
    return this.data?.label ?? "";
  }

  // Started and not ended, by this browser's clock: the page may come from
  // a cache that's older than an ad's start or end
  get items(): JtLine[] {
    const now = Date.now();
    return (this.data?.items ?? []).filter(
      (line) =>
        (!line.s || Date.parse(line.s) <= now) &&
        (!line.e || Date.parse(line.e) > now)
    );
  }

  get line(): JtLine | null {
    const items = this.items;
    if (!items.length) {
      return null;
    }
    // The first pick is made once per page load and isn't tracked: reading
    // the line mustn't change what the page is rendering
    const first = this.#firstPick(items);
    return (
      items.find((line) => line.k === this.current) ??
      items.find((line) => line.k === first) ??
      items[0]
    );
  }

  // What the welcome area shows: the forum's own welcome first, for a new
  // logged-out visitor on a theme that has one, else the ads. Members and
  // anyone here for longer go straight to the ads.
  get stage(): "welcome" | "ads" {
    if (!this.items.length) {
      return "welcome";
    }
    return this.#planIntro() && !this.introOver ? "welcome" : "ads";
  }

  get canVote(): boolean {
    return !!this.currentUser;
  }

  get isStaff(): boolean {
    return !!this.currentUser?.staff;
  }

  vote(line: JtLine): number | null {
    return line.k in this.votes ? this.votes[line.k] : (line.v ?? null);
  }

  tally(line: JtLine): JtLineCounts | null {
    return this.counts[line.k] ?? line.n ?? null;
  }

  // Started by the theme's welcome once it's on the page: after the
  // welcome's seconds, the ads slide in
  startIntro(): () => void {
    if (!this.#planIntro() || this.introOver || this.#introTimer) {
      return () => {};
    }
    const seconds = Math.max(0, this.data?.intro ?? 0);
    this.#introTimer = setTimeout(() => {
      this.#introTimer = null;
      this.introOver = true;
    }, seconds * 1000);
    return () => {
      if (this.#introTimer) {
        clearTimeout(this.#introTimer);
        this.#introTimer = null;
      }
    };
  }

  hostInTheme() {
    this.themeHosted = true;
  }

  // Moves to another line every `every` seconds while the element is on
  // screen, the tab is visible and nobody is pointing at or focused on it.
  // Under reduced motion it stays on one. Returns the cleanup.
  rotate(element: HTMLElement): () => void {
    const every = Math.max(5, this.data?.every ?? 60) * 1000;
    if (this.items.length < 2 || reducedMotion()) {
      return () => {};
    }
    let paused = false;
    const hold = () => (paused = true);
    const release = () => (paused = false);
    element.addEventListener("pointerenter", hold);
    element.addEventListener("pointerleave", release);
    element.addEventListener("focusin", hold);
    element.addEventListener("focusout", release);

    const timer = setInterval(() => {
      const box = element.getBoundingClientRect();
      const onScreen = box.bottom > 0 && box.top < window.innerHeight;
      if (paused || document.hidden || !onScreen) {
        return;
      }
      this.current = this.#pick(this.items, this.line?.k ?? null)?.k ?? null;
    }, every);

    return () => {
      clearInterval(timer);
      element.removeEventListener("pointerenter", hold);
      element.removeEventListener("pointerleave", release);
      element.removeEventListener("focusin", hold);
      element.removeEventListener("focusout", release);
    };
  }

  // Checks, once the page has settled, that the element is really showing.
  // A blocker that hides it by a rule of its own leaves it in the page with
  // no size; then the line moves to the fallback place.
  watch(element: HTMLElement): () => void {
    const check = setTimeout(() => {
      if (document.hidden) {
        return;
      }
      const style = window.getComputedStyle(element);
      const gone =
        element.getClientRects().length === 0 ||
        style.display === "none" ||
        style.visibility === "hidden" ||
        Number(style.opacity) === 0;
      if (gone) {
        this.hidden = true;
      }
    }, 1500);
    return () => clearTimeout(check);
  }

  @action
  async setVote(line: JtLine, value: number) {
    const next = this.vote(line) === value ? 0 : value;
    try {
      const result = await ajax(`/jtech-lines/${line.k}`, {
        type: "PUT",
        data: { value: next },
      });
      this.votes = { ...this.votes, [line.k]: result.v ?? null };
      if (result.n) {
        this.counts = { ...this.counts, [line.k]: result.n };
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  // Decided once per page load and not tracked: reading the stage mustn't
  // change what the page is rendering
  #planIntro(): boolean {
    if (this.#introPlanned === null) {
      const intro = this.data?.intro ?? 0;
      const fresh = (this.data?.fresh ?? 0) * 1000;
      const seen = this.currentUser ? null : firstSeen();
      this.#introPlanned =
        this.themeHosted &&
        !this.currentUser &&
        intro > 0 &&
        seen !== null &&
        Date.now() - seen < fresh;
    }
    return this.#introPlanned;
  }

  #firstPick(items: JtLine[]): string | null {
    this.#first ??= this.#pick(items, null)?.k ?? null;
    return this.#first;
  }

  // A weighted pick, never the same line twice in a row when there's another
  #pick(items: JtLine[], skip: string | null): JtLine | undefined {
    const pool = items.length > 1 ? items.filter((l) => l.k !== skip) : items;
    const total = pool.reduce((sum, l) => sum + Math.max(1, l.w), 0);
    let roll = Math.random() * total;
    for (const line of pool) {
      roll -= Math.max(1, line.w);
      if (roll < 0) {
        return line;
      }
    }
    return pool[0];
  }
}
