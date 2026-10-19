import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { LinkTo } from "@ember/routing";
import { service } from "@ember/service";
import type { ComponentLike } from "@glint/template";
import DToggleSwitchBase from "discourse/components/d-toggle-switch";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import ReqpmService, {
  ReqpmCard,
  ReqpmCurrentUser,
} from "../services/reqpm.ts";
import ReqpmCardEditor from "./reqpm-card-editor.gts";

// Core declares the switch without a signature.
const DToggleSwitch = DToggleSwitchBase as unknown as ComponentLike<{
  Args: { state?: boolean; label?: string; translatedLabel?: string };
  Element: HTMLButtonElement;
}>;

interface ReqpmPreferencesSignature {
  Args: {
    // Whose preferences page this is; the signed-in member when absent.
    user?: { id: number } | null;
    onChange?: (card: ReqpmCard) => void;
    showHeading?: boolean;
    showHubLink?: boolean;
  };
}

// Your own card and the "allow requests" switch. Used on the preferences
// tab and on the REQ-PM page's "My card" tab. Only ever shows the signed-in
// member's own card — an admin opening someone else's preferences gets a
// notice, not their own card by mistake.
export default class ReqpmPreferences extends Component<ReqpmPreferencesSignature> {
  @service declare reqpm: ReqpmService;
  @service declare currentUser: ReqpmCurrentUser | null;

  @tracked card: ReqpmCard | null = null;

  get isOwn(): boolean {
    return !this.args.user || this.args.user.id === this.currentUser?.id;
  }

  @action
  cardChanged(card: ReqpmCard) {
    this.card = card;
    this.args.onChange?.(card);
    if (card.methods.length) {
      this.reqpm.clearSetupPrompt();
    }
  }

  @action
  async toggleAllowRequests() {
    try {
      this.card = await this.reqpm.setAllowRequests(!this.card.allow_requests);
      this.args.onChange?.(this.card);
    } catch (e) {
      popupAjaxError(e);
    }
  }

  <template>
    <div class="reqpm-preferences">
      {{#if this.isOwn}}
        {{#if @showHeading}}
          <h3 class="reqpm-preferences__title">{{i18n
              "reqpm.preferences.title"
            }}</h3>
        {{/if}}
        <ReqpmCardEditor @onChange={{this.cardChanged}} />

        {{#if this.card}}
          <div class="reqpm-setting">
            <DToggleSwitch
              @label="reqpm.hub.allow_requests"
              @state={{this.card.allow_requests}}
              {{on "click" this.toggleAllowRequests}}
            />
          </div>
        {{/if}}

        {{#if @showHubLink}}
          <LinkTo class="reqpm-preferences__hub-link" @route="reqpm">
            {{i18n "reqpm.preferences.open_hub"}}
            →
          </LinkTo>
        {{/if}}
      {{else}}
        <p class="reqpm-muted">{{i18n "reqpm.preferences.not_yours"}}</p>
      {{/if}}
    </div>
  </template>
}
