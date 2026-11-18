import Component from "@glimmer/component";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import JtLine from "../../components/jt-line.gts";
import { onWelcomeRoute } from "../../lib/jt-lines-route.ts";
import type JtLinesService from "../../services/jt-lines.ts";

interface JtLinesOutletSignature {
  Args: { outletArgs: { category?: unknown; tag?: unknown } };
}

// The plain card: the welcome area's line for any theme. A theme that
// carries the line itself (the JTech hero) says so, and this stays out.
export default class JtLinesOutlet extends Component<JtLinesOutletSignature> {
  @service("jt-lines") declare lines: JtLinesService;
  @service declare router: RouterService;

  live = modifier((element: HTMLElement) => {
    const stopRotating = this.lines.rotate(element);
    const stopWatching = this.lines.watch(element);
    return () => {
      stopRotating();
      stopWatching();
    };
  });

  get shown() {
    return this.lines.line ? [this.lines.line] : [];
  }

  get shows(): boolean {
    return (
      !this.lines.themeHosted &&
      !this.lines.hidden &&
      !!this.lines.line &&
      onWelcomeRoute(
        this.router,
        !!(this.args.outletArgs.category || this.args.outletArgs.tag)
      )
    );
  }

  <template>
    {{#if this.shows}}
      <aside class="jt-lines" {{this.live}}>
        {{! keyed, so each new line is drawn fresh and fades in }}
        {{#each this.shown key="k" as |line|}}
          <JtLine @line={{line}} />
        {{/each}}
      </aside>
    {{/if}}
  </template>
}
