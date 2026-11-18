import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import { modifier } from "ember-modifier";
import icon from "discourse/helpers/d-icon";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import type {
  default as JtLinesService,
  JtLine as Line,
} from "../services/jt-lines.ts";

interface JtLineSignature {
  Args: { line: Line; state?: "in" | "out" | "still" };
}

interface AuthSiteSettings {
  allow_new_registrations: boolean;
  invite_only: boolean;
}

function reducedMotion(): boolean {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

const ROOTS = new WeakMap<HTMLElement, ShadowRoot>();

// The kit's rules, copied once from the page into a sheet an app's shadow
// root can adopt, so the kit's classes work inside an app too
let kitSheet: CSSStyleSheet | null = null;
function kit(): CSSStyleSheet {
  if (kitSheet) {
    return kitSheet;
  }
  const rules: string[] = [];
  for (const sheet of Array.from(document.styleSheets)) {
    let list: CSSRuleList;
    try {
      list = sheet.cssRules;
    } catch {
      continue;
    }
    for (const rule of Array.from(list)) {
      const text = rule.cssText;
      if (text.includes(".jl-") || text.includes("@keyframes jl-")) {
        rules.push(text);
      }
    }
  }
  kitSheet = new CSSStyleSheet();
  kitSheet.replaceSync(rules.join("\n"));
  return kitSheet;
}

// Inside every app: it fills the space and stops at its edges; its motion
// pauses off screen or in a hidden tab (.jl-still) and stops for reduced
// motion; the search and sign-up pieces take the theme's look
const BASE = `
  :host { all: initial; display: block; position: absolute; inset: 0;
    contain: strict; color: var(--jl-fg); font: inherit; }
  .jl-app-root { position: absolute; inset: 0; overflow: hidden;
    contain: paint; box-sizing: border-box; font-family: inherit; }
  .jl-app-root *, .jl-app-root *::before, .jl-app-root *::after { box-sizing: border-box; }
  .jl-still, .jl-still * { animation-play-state: paused !important; }
  @media (prefers-reduced-motion: reduce) {
    *, *::before, *::after { animation: none !important; transition: none !important; }
  }
  a { color: inherit; }
  .jl-search-form { display: flex; align-items: center; gap: .4em;
    max-width: 30rem; height: 2.75rem; padding: 0 .3rem 0 .9rem;
    border: 1px solid var(--jl-border); border-radius: var(--jl-radius-lg);
    background: color-mix(in srgb, var(--jl-raised) 80%, transparent); }
  .jl-search-form input { flex: 1; min-width: 0; border: 0; background: none;
    color: var(--jl-fg); font: inherit; outline: none; }
  .jl-search-form button { flex: none; width: 2.1rem; height: 2.1rem; border: 0;
    border-radius: var(--jl-radius); background: var(--jl-accent);
    color: var(--jl-accent-fg); cursor: pointer; font: inherit; }
  .jl-auth-row { display: flex; gap: .5rem; flex-wrap: wrap; }
  .jl-auth-row a { display: inline-flex; align-items: center; padding: .5em 1em;
    border-radius: var(--jl-radius); font-weight: 600; text-decoration: none;
    border: 1px solid var(--jl-border); color: var(--jl-fg); }
  .jl-auth-row a.jl-auth-first { background: var(--jl-accent);
    border-color: var(--jl-accent); color: var(--jl-accent-fg); }
`;

// One ad in its card. Kit ads and headline-and-text ads are drawn here;
// an app (an ad with CSS) runs in a closed shadow root, sealed off from the
// page. The label and thumbs belong to the card, above the ad, and only a
// house ad (the forum's own) goes without them. Drawn by the plugin's plain
// card and, through the service, by a theme that carries the ads.
export default class JtLine extends Component<JtLineSignature> {
  @service("jt-lines") declare lines: JtLinesService;
  @service declare router: RouterService;
  @service declare siteSettings: SiteSettings & AuthSiteSettings;

  mountApp = modifier((host: HTMLElement, [line]: [Line]) => {
    // closed roots can't be looked up again: the host keeps its own, and a
    // re-render refills it
    const root = ROOTS.get(host) ?? host.attachShadow({ mode: "closed" });
    ROOTS.set(host, root);
    root.replaceChildren();
    const base = new CSSStyleSheet();
    base.replaceSync(BASE);
    const own = new CSSStyleSheet();
    try {
      own.replaceSync(line.x ?? "");
    } catch {
      // unparseable CSS: the app shows without it
    }
    root.adoptedStyleSheets = [kit(), base, own];

    const app = document.createElement("div");
    app.className = "jl-app-root";
    // already cleaned on the server (lib/discourse_jtech_ads/app.rb)
    app.innerHTML = line.c ?? "";
    root.append(app);
    this.#widgets(app);

    // still when nobody can see it
    let onScreen = true;
    const still = () =>
      app.classList.toggle("jl-still", !onScreen || document.hidden);
    const watcher = new IntersectionObserver(([entry]) => {
      onScreen = entry.isIntersecting;
      still();
    });
    watcher.observe(host);
    document.addEventListener("visibilitychange", still);
    if (reducedMotion()) {
      app.classList.add("jl-still");
    }

    return () => {
      watcher.disconnect();
      document.removeEventListener("visibilitychange", still);
    };
  });

  get vote() {
    return this.lines.vote(this.args.line);
  }

  get tally() {
    return this.lines.isStaff ? this.lines.tally(this.args.line) : null;
  }

  get cardClass(): string {
    return [
      "jl-card",
      `jl-card--${this.args.state ?? "still"}`,
      this.args.line.x && "jl-card--app",
    ]
      .filter(Boolean)
      .join(" ");
  }

  get showThumbs(): boolean {
    return (
      this.lines.canVote &&
      !this.args.line.o &&
      !this.args.line.preview &&
      this.args.state !== "out"
    );
  }

  get showLabel(): boolean {
    return !this.args.line.o || !!this.args.line.preview;
  }

  // The search and sign-up pieces an app asks for with placeholders, built
  // here from fixed markup: an ad's own HTML can't have forms
  #widgets(app: HTMLElement) {
    app.querySelectorAll<HTMLElement>(".jl-search").forEach((slot) => {
      const form = document.createElement("form");
      form.className = "jl-search-form";
      form.setAttribute("role", "search");
      const input = document.createElement("input");
      input.type = "search";
      input.name = "q";
      input.placeholder = i18n("jt_lines.search");
      input.setAttribute("aria-label", i18n("jt_lines.search"));
      const go = document.createElement("button");
      go.type = "submit";
      go.textContent = "→";
      go.setAttribute("aria-label", i18n("jt_lines.search"));
      form.append(input, go);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        const q = input.value.trim();
        this.router.transitionTo("full-page-search", {
          queryParams: q ? { q } : {},
        });
      });
      slot.replaceChildren(form);
    });

    app.querySelectorAll<HTMLElement>(".jl-auth").forEach((slot) => {
      if (this.lines.currentUser) {
        slot.replaceChildren();
        return;
      }
      const row = document.createElement("div");
      row.className = "jl-auth-row";
      const canSignUp =
        this.siteSettings.allow_new_registrations &&
        !this.siteSettings.invite_only;
      const links: [string, string][] = canSignUp
        ? [
            ["/signup", i18n("sign_up")],
            ["/login", i18n("log_in")],
          ]
        : [["/login", i18n("log_in")]];
      links.forEach(([href, text], index) => {
        const link = document.createElement("a");
        link.href = href;
        link.textContent = text;
        if (index === 0) {
          link.className = "jl-auth-first";
        }
        row.append(link);
      });
      slot.replaceChildren(row);
    });
  }

  <template>
    <div class={{this.cardClass}} inert={{if (eq @state "out") ""}}>
      {{#if this.showLabel}}
        <span class="jt-lines__label">{{if
            @line.preview
            (i18n "jt_lines.preview")
            this.lines.label
          }}</span>
      {{/if}}
      {{#if @line.x}}
        <div class="jl-app" {{this.mountApp @line}}></div>
      {{else if @line.c}}
        {{htmlSafe @line.c}}
      {{else}}
        <div class="jl-stack">
          <h2 class="jl-title" dir="auto">{{htmlSafe @line.h}}</h2>
          {{#if @line.t}}
            <p class="jl-lead" dir="auto">{{htmlSafe @line.t}}</p>
          {{/if}}
        </div>
      {{/if}}
      {{#if this.showThumbs}}
        <div class="jt-lines__thumbs">
          <button
            aria-label={{i18n "jt_lines.up"}}
            aria-pressed={{if (eq this.vote 1) "true" "false"}}
            class="btn-flat no-text jt-lines__thumb"
            title={{i18n "jt_lines.up"}}
            type="button"
            {{on "click" (fn this.lines.setVote @line 1)}}
          >{{icon "thumbs-up"}}</button>
          <button
            aria-label={{i18n "jt_lines.down"}}
            aria-pressed={{if (eq this.vote -1) "true" "false"}}
            class="btn-flat no-text jt-lines__thumb"
            title={{i18n "jt_lines.down"}}
            type="button"
            {{on "click" (fn this.lines.setVote @line -1)}}
          >{{icon "thumbs-down"}}</button>
          {{#if this.tally}}
            <span class="jt-lines__tally">{{i18n
                "jt_lines.counts"
                up=this.tally.up
                down=this.tally.down
              }}</span>
          {{/if}}
        </div>
      {{/if}}
    </div>
  </template>
}

function eq(a: unknown, b: unknown): boolean {
  return a === b;
}
