import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { next } from "@ember/runloop";
import DMenu from "float-kit/components/d-menu";
import PostMenuButtonWrapper from "discourse/components/post/menu/button-wrapper";
import { i18n } from "discourse-i18n";

interface MenuState {
  collapsed: boolean;
  collapsedButtons: unknown[];
}

interface JtPostMenuMoreSignature {
  Args: {
    buttonActions: unknown;
    post: unknown;
    state: MenuState;
  };
  Element: HTMLElement;
}

interface MenuInstance {
  close: () => void;
}

// ⋯ on a phone (api-initializers/jt-phone-post-menu): the post's buttons
// that didn't fit on the menu's line, as a list with their names, in a sheet
// from the bottom of the screen. Core's ⋯ put them back in the line. They're
// the menu's own buttons, so each does what it did there.
export default class JtPostMenuMore extends Component<JtPostMenuMoreSignature> {
  // as core's ⋯: two or more to show (one is shown in the line)
  static shouldRender(args: { state: MenuState }): boolean {
    return args.state.collapsedButtons.length > 1 && args.state.collapsed;
  }

  #menu: MenuInstance | null = null;

  @action
  registerMenu(menu: MenuInstance) {
    this.#menu = menu;
  }

  // Shut once the button has done its part: what it opens (a dialog, its
  // own menu) opens over the sheet's place. Seen on the way down (core's
  // buttons stop their clicks there).
  @action
  shutAfterPick(event: MouseEvent) {
    if ((event.target as Element).closest(".btn")) {
      next(() => this.#menu?.close());
    }
  }

  <template>
    <DMenu
      class="post-action-menu__show-more show-more-actions"
      ...attributes
      @ariaLabel={{i18n "show_more"}}
      @contentClass="jt-post-more"
      @icon="ellipsis"
      @identifier="jt-post-more"
      @modalForMobile={{true}}
      @onRegisterApi={{this.registerMenu}}
      @title={{i18n "show_more"}}
    >
      <:content>
        {{! eslint-disable-next-line ember/template-no-invalid-interactive }}
        <div
          class="jt-post-more__list"
          {{on "click" this.shutAfterPick capture=true}}
        >
          {{#each @state.collapsedButtons as |button|}}
            <PostMenuButtonWrapper
              @buttonActions={{@buttonActions}}
              @buttonConfig={{button}}
              @post={{@post}}
              @state={{@state}}
            />
          {{/each}}
        </div>
      </:content>
    </DMenu>
  </template>
}
