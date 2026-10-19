import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import ModPmBadgePicker, {
  type RecipientsComposer,
} from "../../components/mod-pm-badge-picker.gts";

interface PmBadgeGroupSiteSettings {
  mod_categories_enabled: boolean;
  mod_pm_badge_group_enabled: boolean;
}

interface ModPmBadgeGroupSignature {
  Args: { outletArgs: { model?: RecipientsComposer | null } };
}

// "Add badge group" button rendered inside the composer-fields outlet
// whenever the composer is in private-message mode. Opens a modal that
// resolves a chosen badge to its current holders' usernames and splices
// them into the standard target_recipients field. From that point the PM
// is sent through Discourse's normal PostCreator path with no further
// plugin code — the audience is the snapshot of holders at send time.
export default class ModPmBadgeGroup extends Component<ModPmBadgeGroupSignature> {
  @service declare modal: ModalService;
  @service declare siteSettings: SiteSettings & PmBadgeGroupSiteSettings;
  @service declare currentUser: User | null;

  get composer(): RecipientsComposer | null | undefined {
    return this.args.outletArgs?.model;
  }

  get show(): boolean {
    if (
      !this.siteSettings.mod_categories_enabled ||
      !this.siteSettings.mod_pm_badge_group_enabled ||
      !this.currentUser?.staff
    ) {
      return false;
    }
    const composer = this.composer;
    if (!composer) {
      return false;
    }
    return !!composer.privateMessage;
  }

  @action
  open() {
    const composer = this.composer;
    if (!composer) {
      return;
    }
    this.modal.show(ModPmBadgePicker, { model: { composer } });
  }

  <template>
    {{#if this.show}}
      <DButton
        class="btn-default mod-pm-badge-group-btn"
        @action={{this.open}}
        @icon="certificate"
        @label="discourse_mod_categories.pm_badge.button"
      />
    {{/if}}
  </template>
}
