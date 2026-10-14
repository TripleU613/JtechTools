import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import DMenu from "float-kit/components/d-menu";
import { eq } from "truth-helpers";
import { settings, themePrefix } from "virtual:theme";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import {
  currentDensity,
  DENSITIES,
  type Density,
  setDensity,
} from "../../lib/jt-density";

// The sidebar footer's density button, beside the palette button: how
// tightly topic lists are set (lib/jt-density), with a small picture of each.
export default class JtDensityMenu extends Component {
  // Read when the menu opens: another tab may have changed it
  @tracked density: Density = currentDensity();
  densities = DENSITIES;
  enabled = settings.density_menu;

  @action
  refresh() {
    this.density = currentDensity();
  }

  @action
  choose(density: Density) {
    setDensity(density);
    this.density = density;
  }

  <template>
    {{#if this.enabled}}
      <DMenu
        class="jt-density-menu icon"
        @ariaLabel={{i18n (themePrefix "jt.density.title")}}
        @icon="list"
        @identifier="jt-density-menu"
        @onShow={{this.refresh}}
        @title={{i18n (themePrefix "jt.density.title")}}
        @triggerClass="btn-flat sidebar-footer-actions-button"
      >
        <:content>
          <ul
            aria-label={{i18n (themePrefix "jt.density.title")}}
            class="jt-palettes --density"
            role="menu"
          >
            {{#each this.densities as |density|}}
              <li role="none">
                <button
                  aria-checked={{if (eq density this.density) "true" "false"}}
                  class="btn btn-transparent jt-palettes__option
                    {{if (eq density this.density) '--active'}}"
                  role="menuitemradio"
                  type="button"
                  {{on "click" (fn this.choose density)}}
                >
                  <span class="jt-density-preview --{{density}}">
                    <span></span><span></span><span></span>
                  </span>
                  <span class="jt-palettes__name">
                    {{i18n (themePrefix (concat "jt.density." density))}}
                  </span>
                  {{#if (eq density this.density)}}{{dIcon "check"}}{{/if}}
                </button>
              </li>
            {{/each}}
          </ul>
        </:content>
      </DMenu>
    {{/if}}
  </template>
}
