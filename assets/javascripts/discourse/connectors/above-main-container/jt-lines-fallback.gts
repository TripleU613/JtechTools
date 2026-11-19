import Component from "@glimmer/component";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import { i18n } from "discourse-i18n";
import { onWelcomeRoute } from "../../lib/jt-lines-route.ts";
import type {
  default as JtLinesService,
  JtLine,
} from "../../services/jt-lines.ts";

// Only when the welcome area's line was hidden by a rule of the browser's
// (a blocker): the line again, at the top of the page, inside a closed
// shadow root, which page-level hiding rules can't reach into. Styled with
// the theme's own colour variables, which do reach in. One fallback, no
// nagging: if this is hidden too, nothing more happens.
export default class JtLinesFallback extends Component {
  @service("jt-lines") declare lines: JtLinesService;
  @service declare router: RouterService;

  mount = modifier((host: HTMLElement, [line]: [JtLine]) => {
    // closed roots can't be looked up again, so the element keeps its own
    let root = ROOTS.get(host);
    if (!root) {
      root = host.attachShadow({ mode: "closed" });
      root.innerHTML = `<style>${STYLE}</style><div class="box"></div>`;
      ROOTS.set(host, root);
    }
    const box = root.querySelector<HTMLElement>(".box")!;
    box.innerHTML = `<b class="tag"></b><p class="head" dir="auto">${line.h}</p>${
      line.t ? `<p class="text" dir="auto">${line.t}</p>` : ""
    }`;
    box.querySelector(".tag")!.textContent = this.lines.label;
    if (this.lines.canVoteOn(line)) {
      const row = document.createElement("div");
      row.className = "row";
      const status = document.createElement("span");
      status.setAttribute("role", "status");
      row.append(status);
      for (const [value, key] of [
        [1, "jt_lines.up"],
        [-1, "jt_lines.down"],
      ] as const) {
        const button = document.createElement("button");
        button.type = "button";
        button.textContent = value > 0 ? "▲" : "▼";
        button.title = i18n(key);
        button.dataset.vote = String(value);
        button.setAttribute("aria-label", i18n(key));
        button.addEventListener("click", () => this.lines.setVote(line, value));
        row.append(button);
      }
      box.append(row);
    }
    return () => (box.innerHTML = "");
  });

  updateFeedback = modifier((host: HTMLElement, [line]: [JtLine]) => {
    const row = ROOTS.get(host)?.querySelector(".row");
    if (row) {
      const vote = this.lines.vote(line);
      const pending = this.lines.isVotePending(line);
      row.querySelector('[role="status"]')!.textContent =
        this.lines.voteFeedback(line);
      for (const button of row.querySelectorAll<HTMLButtonElement>("button")) {
        button.setAttribute(
          "aria-pressed",
          String(vote === Number(button.dataset.vote))
        );
        button.setAttribute("aria-disabled", String(pending));
      }
    }
  });

  get line(): JtLine | null {
    if (!this.lines.hidden || !onWelcomeRoute(this.router, false)) {
      return null;
    }
    return this.lines.line;
  }

  <template>
    {{#if this.line}}
      <div
        data-jt-l
        {{this.mount this.line}}
        {{this.updateFeedback this.line}}
      ></div>
    {{/if}}
  </template>
}

const ROOTS = new WeakMap<HTMLElement, ShadowRoot>();

// Line headlines and text are already cleaned to inline tags on the server
const STYLE = `
  :host { display: block; margin: 0 0 1em; }
  .box {
    display: flex; flex-wrap: wrap; align-items: baseline; gap: .25em .75em;
    padding: .75em 1em; border: 1px solid var(--primary-low, #ddd);
    border-radius: var(--d-border-radius, 6px);
    background: var(--secondary, #fff); color: var(--primary, #222);
    font: inherit;
  }
  .tag { font-size: .75em; font-weight: 600; color: var(--primary-medium, #888); }
  .head { margin: 0; font-weight: 600; }
  .text { margin: 0; flex-basis: 100%; color: var(--primary-high, #444); }
  a { color: var(--tertiary, #08c); }
  .row { margin-left: auto; display: flex; align-items: center; gap: .25em; }
  [role="status"] { font-size: .875em; }
  button {
    border: 0; background: none; color: var(--primary-medium, #888);
    cursor: pointer; padding: .25em .4em; border-radius: 4px;
  }
  button:hover { background: var(--primary-very-low, #f3f3f3); }
  button[aria-pressed="true"] { background: var(--tertiary); color: var(--secondary); }
  button[aria-disabled="true"] { cursor: wait; }
`;
