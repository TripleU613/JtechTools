import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action, get } from "@ember/object";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import type User from "discourse/models/user";
import type Header from "discourse/services/header";
import type InterfaceColor from "discourse/services/interface-color";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { toggleColorMode } from "../lib/jt-color-mode.ts";
import { jtLabel } from "../lib/jt-labels.ts";
import { needsFullPageLoad } from "../lib/jt-links.ts";
import { pickUserMenuTab } from "../lib/jt-user-menu.ts";

export type JtHeaderIconKind = "home" | "messages" | "notifications" | "theme";

type HeaderIconUser = User & {
  all_unread_notifications_count?: number;
  new_personal_messages_notifications_count?: number;
};

interface JtHeaderIconSignature {
  Args: {
    kind: JtHeaderIconKind;
    href?: string;
  };
}

const count = new Intl.NumberFormat(undefined, { notation: "compact" });

// One header icon button. Kinds:
//  - home: a link (settings.header_home_url)
//  - notifications / messages: open core's user menu on that tab, with the
//    unread count as a badge (core's own menu, nothing duplicated)
//  - theme: light / dark
export default class JtHeaderIcon extends Component<JtHeaderIconSignature> {
  @service declare currentUser: HeaderIconUser | null;
  @service declare header: Header;
  @service declare interfaceColor: InterfaceColor;
  @service declare router: RouterService;

  get kind(): JtHeaderIconKind {
    return this.args.kind;
  }

  get label(): string {
    return jtLabel(`header.${this.kind}`);
  }

  get icon(): string {
    return {
      home: "house",
      messages: "envelope",
      notifications: "bell",
      theme: "circle-half-stroke",
    }[this.kind];
  }

  get unread(): number {
    const user = this.currentUser;
    if (!user) {
      return 0;
    }
    // get(): these are classic model properties; a plain read wouldn't be
    // tracked, so the badge would never update
    if (this.kind === "notifications") {
      return get(user, "all_unread_notifications_count") || 0;
    }
    if (this.kind === "messages") {
      return get(user, "new_personal_messages_notifications_count") || 0;
    }
    return 0;
  }

  get badge(): string | null {
    return this.unread > 0 ? count.format(this.unread) : null;
  }

  get fullPage(): boolean {
    return needsFullPageLoad(this.router, this.args.href);
  }

  get tab(): string {
    return this.kind === "messages" ? "messages" : "all-notifications";
  }

  @action
  activate() {
    if (this.kind === "theme") {
      return toggleColorMode(this.interfaceColor);
    }

    const tabButton = () =>
      document.getElementById(`user-menu-button-${this.tab}`);
    const onThisTab = tabButton()?.classList.contains("active");

    if (this.header.userVisible && onThisTab) {
      document.getElementById("toggle-current-user")?.click(); // close
      return;
    }
    if (!this.header.userVisible) {
      document.getElementById("toggle-current-user")?.click();
    }
    // If core's menu ever changes shape, fall back to the full page
    pickUserMenuTab(this.tab, () => {
      if (this.header.userVisible) {
        document.getElementById("toggle-current-user")?.click(); // close
      }
      this.router.transitionTo(
        this.kind === "messages" ? "/my/messages" : "/my/notifications"
      );
    });
  }

  <template>
    <li class="header-dropdown-toggle jt-header-{{this.kind}}">
      {{#if @href}}
        <a
          aria-label={{this.label}}
          class="btn btn-flat no-text icon jt-header-icon"
          data-auto-route={{if this.fullPage "true"}}
          href={{@href}}
          title={{this.label}}
        >{{dIcon this.icon}}</a>
      {{else}}
        <button
          aria-label={{this.label}}
          class="btn btn-flat no-text icon jt-header-icon"
          title={{this.label}}
          type="button"
          {{on "click" this.activate}}
        >
          {{dIcon this.icon}}
          {{#if this.badge}}
            <span class="jt-header-icon__badge">{{this.badge}}</span>
          {{/if}}
        </button>
      {{/if}}
    </li>
  </template>
}
