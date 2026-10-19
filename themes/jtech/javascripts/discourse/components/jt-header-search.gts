import Component from "@glimmer/component";
import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import { themePrefix } from "virtual:theme";
import type { CapabilitiesService } from "discourse/services/capabilities";
import type ModalService from "discourse/services/modal";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { commandMenuShortcutBound } from "../lib/jt-command-menu-shortcut.ts";
import JtCommandMenu from "./jt-command-menu.gts";

interface SearchButtonSignature {
  Args: {
    open: () => void;
    showKeys: boolean;
    modKey: string;
  };
}

interface JtHeaderSearchSignature {
  Args: {
    centered?: boolean;
  };
}

const SearchButton: TemplateOnlyComponent<SearchButtonSignature> = <template>
  <button
    aria-label={{i18n (themePrefix "jt.cmdk.sidebar_label")}}
    class="jt-header-search__button"
    title={{i18n (themePrefix "jt.cmdk.sidebar_label")}}
    type="button"
    {{on "click" @open}}
  >
    {{dIcon "magnifying-glass"}}
    <span class="jt-header-search__label" dir="auto">{{i18n
        (themePrefix "jt.header.search")
      }}</span>
    {{#if @showKeys}}
      <span aria-hidden="true" class="jt-header-search__keys">
        <kbd>{{@modKey}}</kbd><kbd>K</kbd>
      </span>
    {{/if}}
  </button>
</template>;

// Header search: a field-shaped button ("Search… ⌘K") that opens the
// command menu. Rendered twice: in the middle of the header (@centered, wide
// screens with a mouse) and in the icon row, where it's the field otherwise
// and an icon on narrow screens; jt-header.scss shows one of them. The key
// hint only shows when the keys really open it.
export default class JtHeaderSearch extends Component<JtHeaderSearchSignature> {
  @service declare capabilities: CapabilitiesService;
  @service declare modal: ModalService;

  showKeys = commandMenuShortcutBound(getOwner(this));

  get modKey(): string {
    return this.capabilities.isApple ? "⌘" : "Ctrl";
  }

  @action
  open() {
    this.modal.show(JtCommandMenu, undefined);
  }

  <template>
    {{#if @centered}}
      <div class="jt-header-search jt-header-search--centered">
        <SearchButton
          @modKey={{this.modKey}}
          @open={{this.open}}
          @showKeys={{this.showKeys}}
        />
      </div>
    {{else}}
      <li class="header-dropdown-toggle jt-header-search">
        <SearchButton
          @modKey={{this.modKey}}
          @open={{this.open}}
          @showKeys={{this.showKeys}}
        />
      </li>
    {{/if}}
  </template>
}
