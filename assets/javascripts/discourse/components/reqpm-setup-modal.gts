import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import ReqpmService, {
  ReqpmCard,
  ReqpmCurrentUser,
  ReqpmSetupMode,
} from "../services/reqpm.ts";
import ReqpmCardEditor from "./reqpm-card-editor.gts";

interface ReqpmSetupModalSignature {
  Args: {
    model: { mode: ReqpmSetupMode };
    closeModal: () => void;
  };
}

// "Add a way for members to reach you" — shown to anyone who has nothing on
// their card yet, new and existing members alike. Gentle mode offers
// "Remind me later" and "I'd rather not"; required mode can only be closed
// by adding something (there is still a way to log out).
export default class ReqpmSetupModal extends Component<ReqpmSetupModalSignature> {
  @service declare reqpm: ReqpmService;
  @service declare currentUser: ReqpmCurrentUser;

  @tracked count = 0;
  @tracked busy = false;

  get required(): boolean {
    return this.args.model?.mode === "required";
  }

  get done(): boolean {
    return this.count > 0;
  }

  get dismissable(): boolean {
    return !this.required || this.done;
  }

  @action
  cardChanged(card: ReqpmCard) {
    this.count = card?.methods?.length || 0;
    if (this.done) {
      this.reqpm.clearSetupPrompt();
    }
  }

  @action
  finish() {
    this.args.closeModal();
  }

  @action
  async later() {
    this.busy = true;
    try {
      await this.reqpm.snoozeSetup();
      this.reqpm.clearSetupPrompt();
      this.args.closeModal();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  }

  @action
  async never() {
    this.busy = true;
    try {
      await this.reqpm.declineSetup();
      this.reqpm.clearSetupPrompt();
      this.args.closeModal();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  }

  @action
  logout() {
    this.currentUser.destroySession(undefined);
  }

  <template>
    <DModal
      class="reqpm-setup-modal"
      @closeModal={{if this.dismissable @closeModal}}
      @dismissable={{this.dismissable}}
      @title={{i18n "reqpm.setup.title"}}
    >
      <:body>
        <p class="reqpm-setup-modal__lead">{{i18n "reqpm.setup.lead"}}</p>

        <ReqpmCardEditor @onChange={{this.cardChanged}} @startAdding={{true}} />
      </:body>
      <:footer>
        {{#if this.done}}
          <DButton
            class="btn-primary"
            @action={{this.finish}}
            @icon="check"
            @label="reqpm.setup.done"
          />
        {{else if this.required}}
          <span class="reqpm-muted reqpm-setup-modal__required">{{i18n
              "reqpm.setup.required_note"
            }}</span>
          <DButton
            class="btn-flat"
            @action={{this.logout}}
            @label="reqpm.setup.log_out"
          />
        {{else}}
          <DButton
            class="btn-default"
            @action={{this.later}}
            @disabled={{this.busy}}
            @label="reqpm.setup.later"
          />
          <DButton
            class="btn-flat"
            @action={{this.never}}
            @disabled={{this.busy}}
            @label="reqpm.setup.never"
          />
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
