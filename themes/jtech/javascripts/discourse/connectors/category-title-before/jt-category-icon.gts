import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { schedule } from "@ember/runloop";
import { type TrustedHTML, trustHTML } from "@ember/template";
import { modifier } from "ember-modifier";
import type Category from "discourse/models/category";
import { eq } from "discourse/truth-helpers";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { dEmoji } from "../../lib/jt-core-helpers.ts";

type IconCategory = Category & { style_type?: "icon" | "emoji" | "square" };

interface JtCategoryIconSignature {
  Args: { outletArgs: { category?: IconCategory | null } };
}

// The Category Boxes component (shared with Default) shows two letters ("Gc")
// in a tile when a category has no uploaded logo. Put the category's own icon
// / emoji / colour square in that tile instead. Renders into the tile with
// in-element; anywhere else this outlet appears (core titles already carry
// the icon in their badge) it renders nothing.
export default class JtCategoryIcon extends Component<JtCategoryIconSignature> {
  @tracked tile: Element | null = null;

  // Modifiers run while the outlet renders, and the template has just read
  // `tile`; setting it in the same pass is a backtracking re-render (Ember
  // asserts in development). Set it once that render is done.
  findTile = modifier((marker: HTMLElement) => {
    schedule("afterRender", () => {
      if (this.isDestroying) {
        return;
      }
      const tile =
        marker
          .closest(".custom-category-boxes .category-box-inner")
          ?.querySelector(":scope > .category-logo.no-logo-present") || null;
      if (tile !== this.tile) {
        this.tile = tile;
      }
    });
  });

  get category(): IconCategory | null | undefined {
    return this.args.outletArgs.category;
  }

  get styleType() {
    return this.category?.style_type;
  }

  get squareStyle(): TrustedHTML {
    return trustHTML(`background-color: #${this.category?.color}`);
  }

  <template>
    <span hidden {{this.findTile}}></span>
    {{#if this.tile}}
      {{#in-element this.tile insertBefore=null}}
        <span aria-hidden="true" class="jt-cat-icon">
          {{#if (eq this.styleType "icon")}}
            {{dIcon this.category.icon}}
          {{else if (eq this.styleType "emoji")}}
            {{dEmoji this.category.emoji}}
          {{else}}
            <span class="jt-cat-icon__square" style={{this.squareStyle}}></span>
          {{/if}}
        </span>
      {{/in-element}}
    {{/if}}
  </template>
}
