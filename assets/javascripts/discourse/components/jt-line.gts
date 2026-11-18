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

// One line's content: the label, headline, text, and the thumbs. Shared by
// the plain card and the fallback; the JTech theme's hero draws its own.
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
    <div class="jt-lines__body">
      <span class="jt-lines__label">{{this.lines.label}}</span>
      <p class="jt-lines__head" dir="auto">{{htmlSafe @line.h}}</p>
      {{#if @line.t}}
        <p class="jt-lines__text" dir="auto">{{htmlSafe @line.t}}</p>
      {{/if}}
    </div>
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
  </template>
}

function eq(a: unknown, b: unknown): boolean {
  return a === b;
}
