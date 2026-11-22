import Component from "@glimmer/component";
import type Owner from "@ember/owner";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import JtLine from "../../components/jt-line.gts";
import { onWelcomeRoute } from "../../lib/jt-lines-route.ts";
import type JtLinesService from "../../services/jt-lines.ts";

// Only when the welcome area's ad was hidden by something in the browser
// (a blocker or an extension): the same card again, at the top of the page,
// inside a closed shadow root. Everything a hiding rule or script keys on
// is kept out of the page: no fixed class, id or data attribute on what's
// outside the root, and nothing of the card is in the page itself. If a
// script still sets it hidden, that's undone. One fallback, no nagging.
//
// .github/workflows/ad-remover-check.yml runs the published remover
// extension against this every day (spec/system/ads_remover_spec.rb).
export default class JtLinesFallback extends Component {
  @service("jt-lines") declare lines: JtLinesService;
  @service declare router: RouterService;

  // A fresh class every page load, so no page rule can name it
  hostClass = `c${Math.random().toString(36).slice(2, 9)}`;
  host = document.createElement("div");
  inner = document.createElement("div");

  place = modifier((slot: HTMLElement) => {
    slot.append(this.host);
    const heal = new MutationObserver(() => this.#heal(slot));
    heal.observe(slot, { attributes: true });
    heal.observe(this.host, { attributes: true });
    this.#heal(slot);

    // the thumbs' icons point into the page's sprite, which a shadow root
    // can't see: the root carries its own copies
    const icons = new MutationObserver(() => this.#icons());
    icons.observe(this.inner, { childList: true, subtree: true });
    this.#icons();

    const stops = [this.lines.rotate(this.inner)];
    return () => {
      heal.disconnect();
      icons.disconnect();
      stops.forEach((stop) => stop());
      this.host.remove();
    };
  });

  #root: ShadowRoot;
  #sprite = document.createElementNS("http://www.w3.org/2000/svg", "svg");

  constructor(owner: Owner, args: object) {
    super(owner, args);
    this.host.className = this.hostClass;
    this.#root = this.host.attachShadow({ mode: "closed" });
    this.#root.adoptedStyleSheets = [sheet()];
    this.#sprite.setAttribute("hidden", "");
    this.inner.className = "jt-lines";
    this.#root.append(this.#sprite, this.inner);
  }

  get shown() {
    if (!this.lines.hidden || !onWelcomeRoute(this.router, false)) {
      return null;
    }
    return this.lines.line ? this.lines.shown : null;
  }

  // Put back what a hiding script changes: its inline style, its marks
  #heal(slot: HTMLElement) {
    for (const element of [slot, this.host]) {
      const style = element.style;
      if (
        style.display ||
        style.visibility ||
        style.opacity ||
        style.height ||
        style.position
      ) {
        element.removeAttribute("style");
      }
      if (element.hidden) {
        element.hidden = false;
      }
      for (const attribute of Array.from(element.attributes)) {
        if (attribute.name !== "class") {
          element.removeAttribute(attribute.name);
        }
      }
    }
    if (slot.className !== this.hostClass) {
      slot.className = this.hostClass;
    }
    if (this.host.className !== this.hostClass) {
      this.host.className = this.hostClass;
    }
  }

  #icons() {
    for (const use of this.inner.querySelectorAll("use")) {
      const id = (use.getAttribute("href") ?? "").replace(/^#/, "");
      if (id && !this.#sprite.querySelector(`[id="${CSS.escape(id)}"]`)) {
        const symbol = document.getElementById(id);
        if (symbol) {
          this.#sprite.append(symbol.cloneNode(true));
        }
      }
    }
  }

  <template>
    {{#if this.shown}}
      <div class={{this.hostClass}} {{this.place}}></div>
      {{#in-element this.inner insertBefore=null}}
        {{#each this.shown key="line.k" as |item|}}
          <JtLine @line={{item.line}} @state={{item.state}} />
        {{/each}}
      {{/in-element}}
    {{/if}}
  </template>
}

// The card's own rules (lines.scss) and the bits of core's it uses (the
// thumbs' buttons and icons), copied once from the forum's own stylesheets
// into a sheet the root adopts. Only sheets the forum serves: never a rule
// something else put in the page.
let copied: CSSStyleSheet | null = null;
function sheet(): CSSStyleSheet {
  if (copied) {
    return copied;
  }
  const wanted = /\.jt-lines|\.jl-|@keyframes jl-|\.btn-flat|\.d-icon/;
  const rules: string[] = [
    ":host { display: block; margin: 0 0 1em; }",
    ".jt-lines { box-sizing: border-box; }",
  ];
  for (const styleSheet of Array.from(document.styleSheets)) {
    if (!ours(styleSheet)) {
      continue;
    }
    let list: CSSRuleList;
    try {
      list = styleSheet.cssRules;
    } catch {
      continue;
    }
    for (const rule of Array.from(list)) {
      if (wanted.test(rule.cssText)) {
        rules.push(rule.cssText);
      }
    }
  }
  copied = new CSSStyleSheet();
  copied.replaceSync(rules.join("\n"));
  return copied;
}

function ours(styleSheet: CSSStyleSheet): boolean {
  if (!styleSheet.href) {
    return false;
  }
  try {
    return new URL(styleSheet.href).pathname.includes("/stylesheets/");
  } catch {
    return false;
  }
}
