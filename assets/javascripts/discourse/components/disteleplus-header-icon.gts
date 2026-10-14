import Component from "@glimmer/component";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import icon from "discourse/helpers/d-icon";
import getURL from "discourse/lib/get-url";
import type Site from "discourse/models/site";
import { i18n } from "discourse-i18n";
import type DisteleplusService from "../services/disteleplus";

interface DisteleplusHeaderIconSignature {
  Args: Record<string, never>;
}

// Header shortcut, modelled on core Chat's header icon: on desktop it toggles
// the bottom-right drawer (unless the user chose full page); on mobile it
// opens the full-page route. Rendered only for users the server allows.
export default class DisteleplusHeaderIcon extends Component<DisteleplusHeaderIconSignature> {
  @service declare disteleplus: DisteleplusService;
  @service declare site: Site;
  @service declare router: RouterService;

  constructor(owner: Owner, args: DisteleplusHeaderIconSignature["Args"]) {
    super(owner, args);
    this.disteleplus.ensureLoaded().catch(() => {});
  }

  get href(): string {
    return getURL("/disteleplus");
  }

  get isActive(): boolean {
    return this.disteleplus.isActive;
  }

  get showBadge(): boolean {
    return (
      this.disteleplus.unreadMentionCount > 0 && !this.disteleplus.isActive
    );
  }

  // Mirrors Chat's header icon: full page on mobile or when the user chose
  // it; otherwise toggle the drawer. The href stays for middle-click.
  @action
  async open(event?: Event) {
    event?.preventDefault?.();

    // On the full page: leave it. Desktop goes back to the previous page with
    // the drawer open (Chat's "exit" behaviour); mobile just goes back.
    if (this.disteleplus.isFullPageActive) {
      const back = this.disteleplus.lastAppURL || "/";
      if (this.site.mobileView) {
        this.router.transitionTo(back).catch(() => {});
        return;
      }
      this.disteleplus.prefersDrawer();
      await this.router.transitionTo(back).catch(() => {});
      this.disteleplus.openDrawer();
      return;
    }

    if (this.site.mobileView || this.disteleplus.isFullPagePreferred) {
      this.router.transitionTo("/disteleplus").catch(() => {});
      return;
    }

    if (this.disteleplus.isDrawerActive) {
      this.disteleplus.closeDrawer();
    } else {
      this.disteleplus.openDrawer();
    }
  }

  <template>
    <li
      class="header-dropdown-toggle disteleplus-header-icon
        {{if this.isActive 'active'}}"
    >
      <DButton
        class="icon btn-flat {{if this.isActive 'active'}}"
        @action={{this.open}}
        @forwardEvent={{true}}
        @href={{this.href}}
        @translatedAriaLabel={{i18n "disteleplus.title"}}
        @translatedTitle={{i18n "disteleplus.title"}}
      >
        {{icon (if this.disteleplus.isFullPageActive "shuffle" "comments")}}
        {{#if this.showBadge}}
          <span class="disteleplus-header-icon__badge">
            {{this.disteleplus.unreadMentionCount}}
          </span>
        {{/if}}
      </DButton>
    </li>
  </template>
}
