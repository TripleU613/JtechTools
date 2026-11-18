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
    const stops = [
      this.lines.startIntro(),
      this.lines.rotate(element),
      this.lines.watch(element),
    ];
    return () => stops.forEach((stop) => stop());
  });

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
        {{#each this.lines.shown key="line.k" as |item|}}
          <JtLine @line={{item.line}} @state={{item.state}} />
        {{/each}}
      </aside>
    {{/if}}
  </template>
}
