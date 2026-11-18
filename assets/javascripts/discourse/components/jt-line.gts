import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import { htmlSafe } from "@ember/template";
import icon from "discourse/helpers/d-icon";
import { i18n } from "discourse-i18n";
import type {
  default as JtLinesService,
  JtLine as Line,
} from "../services/jt-lines.ts";

interface JtLineSignature {
  Args: { line: Line };
}

// One ad, filling its card: the label, then either the whole-card HTML or
// the headline and text, and the thumbs. Drawn by the plugin's plain card
// and, through the service, by a theme that carries the ads (the JTech hero).
// Class names stay neutral (docs/features/ads.md, "Naming").
export default class JtLine extends Component<JtLineSignature> {
  @service("jt-lines") declare lines: JtLinesService;

  get vote() {
    return this.lines.vote(this.args.line);
  }

  get tally() {
    return this.lines.isStaff ? this.lines.tally(this.args.line) : null;
  }

  <template>
    <div class="jl-card">
      <span class="jt-lines__label">{{this.lines.label}}</span>
      {{#if @line.c}}
        {{htmlSafe @line.c}}
      {{else}}
        <div class="jl-stack">
          <h2 class="jl-title" dir="auto">{{htmlSafe @line.h}}</h2>
          {{#if @line.t}}
            <p class="jl-lead" dir="auto">{{htmlSafe @line.t}}</p>
          {{/if}}
        </div>
      {{/if}}
      {{#if this.lines.canVote}}
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
