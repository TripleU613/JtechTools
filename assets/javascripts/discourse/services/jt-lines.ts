import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import Service, { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import { i18n } from "discourse-i18n";
import JtLineCard from "../components/jt-line.gts";

// The ads for the home page's welcome area (lib/discourse_jtech_ads.rb,
// docs/features/ads.md). They arrive inside the preloaded site data as
// site.jt_lines. Nothing in the browser is named after ads: blockers hide
// elements and requests by names like that.

export interface JtLine {
  k: string; // key
  h: string; // headline, cleaned HTML
  t: string; // text, cleaned HTML
  c?: string | null; // the whole card, cleaned HTML of the kit (optional)
  w: number; // weight
  s?: string | null; // starts
  e?: string | null; // ends
  v?: number | null; // this member's thumbs (members only)
  x?: string | null; // the card's own CSS: then it's an app (shadow root)
  o?: boolean | null; // the forum's own (house): no label, no thumbs
  i?: boolean | null; // the welcome: shown first to new visitors
  preview?: boolean; // an admin's preview (?jl_preview=…), seen by them only
}

// One ad on the page and its part in a swap: arriving, leaving, or just
// there. Both stay mounted for the length of a transition.
export interface JtShown {
  line: JtLine;
  state: "in" | "out" | "still";
}

// How long the outgoing ad stays mounted during a swap (lines.scss times
// its transition inside this)
const SWAP_MS = 1100;

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
  @service declare currentUser: (User & { admin?: boolean }) | null;

  // The key of the line showing, once rotation has moved on from the first
  @tracked current: string | null = null;
  // The page's renderer got hidden (a blocker's element rule): show the
  // line in the fallback place instead
  @tracked hidden = false;
  @tracked votes: Record<string, number | null> = {};
  // The welcome's time is up and the ads have slid in
  @tracked introOver = false;
  // An admin's preview (?jl_preview=…): this one ad only, for them only
  @tracked preview: JtLine | null = null;
  // The ad on its way out during a swap
  @tracked leaving: JtLine | null = null;

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
  #leaveTimer: ReturnType<typeof setTimeout> | undefined;
  @tracked _pendingVotes = new Set<string>();

  constructor(owner: Owner) {
    super(owner);
    this.#loadPreview();
  }

  get data(): JtLines | null {
    return this.site.jt_lines ?? null;
  }

  get label(): string {
    return this.data?.label ?? "";
  }

  // Started and not ended, by this browser's clock: the page may come from
  // a cache that's older than an ad's start or end
  get items(): JtLine[] {
    if (this.preview) {
      return [this.preview];
    }
    const now = Date.now();
    return (this.data?.items ?? []).filter(
      (line) =>
        (!line.s || Date.parse(line.s) <= now) &&
        (!line.e || Date.parse(line.e) > now)
    );
  }

  // The welcome app, if there is one for this person
  get introLine(): JtLine | null {
    return this.items.find((line) => line.i) ?? null;
  }

  get line(): JtLine | null {
    const items = this.items;
    if (!items.length) {
      return null;
    }
    if (this.stage === "welcome" && this.introLine) {
      return this.introLine;
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
    if (this.preview) {
      return "ads";
    }
    return this.#planIntro() && !this.introOver ? "welcome" : "ads";
  }

  // The ads on the page now: the one showing, and during a swap the one
  // leaving too
  get shown(): JtShown[] {
    const line = this.line;
    const leaving = this.leaving;
    const shown: JtShown[] = [];
    if (leaving && leaving.k !== line?.k) {
      shown.push({ line: leaving, state: "out" });
    }
    if (line) {
      shown.push({ line, state: shown.length ? "in" : "still" });
    }
    return shown;
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

  canVoteOn(line: JtLine): boolean {
    return this.canVote && !line.o && !line.preview;
  }

  isVotePending(line: JtLine): boolean {
    return this._pendingVotes.has(line.k);
  }

  voteFeedback(line: JtLine): string {
    if (this.isVotePending(line)) {
      return i18n("jt_lines.vote_saving");
    }

    switch (this.vote(line)) {
      case 1:
        return i18n("jt_lines.vote_liked");
      case -1:
        return i18n("jt_lines.vote_disliked");
      default:
        return line.k in this.votes ? i18n("jt_lines.vote_removed") : "";
    }
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
      const intro = this.introLine;
      if (intro) {
        // the welcome app hands over to another ad, as a swap
        const next = this.#pick(this.items, intro.k);
        this.introOver = true;
        this.#swapTo(next?.k ?? null, intro);
      } else {
        this.introOver = true;
      }
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
      if (paused || document.hidden || !onScreen || this.stage === "welcome") {
        return;
      }
      this.#swapTo(this.#pick(this.items, this.line?.k ?? null)?.k ?? null);
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
  async setVote(line: JtLine, value: -1 | 1) {
    if (!this.canVoteOn(line) || this.isVotePending(line)) {
      return;
    }

    const next = this.vote(line) === value ? 0 : value;
    this._pendingVotes = new Set(this._pendingVotes).add(line.k);
    try {
      const result: { v: -1 | 1 | null } = await ajax(
        `/jtech-lines/${line.k}`,
        {
          type: "PUT",
          data: { value: next },
        }
      );
      this.votes = { ...this.votes, [line.k]: result.v ?? null };
    } catch (error) {
      popupAjaxError(error);
    } finally {
      const pending = new Set(this._pendingVotes);
      pending.delete(line.k);
      this._pendingVotes = pending;
    }
  }

  // Decided once per page load and not tracked: reading the stage mustn't
  // change what the page is rendering
  #planIntro(): boolean {
    if (this.#introPlanned === null) {
      const intro = this.data?.intro ?? 0;
      const fresh = (this.data?.fresh ?? 0) * 1000;
      const seen = this.currentUser ? null : firstSeen();
      const introApp = (this.data?.items ?? []).some((line) => line.i);
      this.#introPlanned =
        (this.themeHosted || introApp) &&
        !this.currentUser &&
        intro > 0 &&
        seen !== null &&
        Date.now() - seen < fresh;
    }
    return this.#introPlanned;
  }

  async #loadPreview() {
    const token = new URLSearchParams(window.location.search).get("jl_preview");
    if (!token || !this.currentUser?.admin || !/^[0-9a-f]{24}$/.test(token)) {
      return;
    }
    try {
      this.preview = await ajax(`/jtech-lines/preview/${token}`);
    } catch (error) {
      popupAjaxError(error);
    }
  }

  // Shows another ad, keeping the one before mounted while they swap
  #swapTo(key: string | null, from: JtLine | null = this.line) {
    this.current = key;
    if (!from || from.k === key || reducedMotion()) {
      return;
    }
    this.leaving = from;
    clearTimeout(this.#leaveTimer);
    this.#leaveTimer = setTimeout(() => (this.leaving = null), SWAP_MS);
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
