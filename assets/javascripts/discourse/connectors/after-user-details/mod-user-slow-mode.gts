import Component from "@glimmer/component";
import { action, get } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import type DialogService from "discourse/dialog-holder/services/dialog";
import type ToastsService from "discourse/float-kit/services/toasts";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { longDate } from "discourse/lib/formatter";
import type ModalService from "discourse/services/modal";
import { i18n } from "discourse-i18n";
import ModUserSlowModeModal, {
  type SlowModeAdminUser,
} from "../../components/mod-user-slow-mode-modal.gts";
import {
  type SlowModeAdminSummary,
  slowModeInterval,
} from "../../lib/mod-slow-mode.ts";

interface ModUserSlowModeSignature {
  Args: { outletArgs: { model: SlowModeAdminUser } };
}

// The user's slow mode on their admin page, laid out like core's Silenced
// row above it.
export default class ModUserSlowMode extends Component<ModUserSlowModeSignature> {
  @service declare dialog: DialogService;
  @service declare modal: ModalService;
  @service declare toasts: ToastsService;

  get user(): SlowModeAdminUser {
    return this.args.outletArgs.model;
  }

  // `can_set_mod_slow_mode` is only sent while the feature is on; staff
  // can't be in slow mode, so their page has no row at all.
  get show(): boolean {
    return (
      get(this.user, "can_set_mod_slow_mode") !== undefined &&
      !get(this.user, "admin") &&
      !get(this.user, "moderator")
    );
  }

  get canSet(): boolean {
    return get(this.user, "can_set_mod_slow_mode") === true;
  }

  get slowMode(): SlowModeAdminSummary | null {
    return get(this.user, "mod_slow_mode") ?? null;
  }

  get status(): string {
    const slowMode = this.slowMode;
    if (!slowMode) {
      return i18n("discourse_mod_categories.slow_mode.none");
    }
    const interval = slowModeInterval(slowMode.seconds);
    if (!slowMode.ends_at) {
      return i18n("discourse_mod_categories.slow_mode.status", { interval });
    }
    return i18n("discourse_mod_categories.slow_mode.status_until", {
      interval,
      date: longDate(new Date(slowMode.ends_at)),
    });
  }

  @action
  openModal() {
    this.modal.show(ModUserSlowModeModal, { model: { user: this.user } });
  }

  @action
  lift() {
    this.dialog.yesNoConfirm({
      message: i18n("discourse_mod_categories.slow_mode.lift_confirm", {
        username: get(this.user, "username"),
      }),
      didConfirm: async () => {
        try {
          await ajax(
            `/discourse-mod-categories/user/${get(this.user, "id")}/slow-mode`,
            { type: "DELETE" }
          );
          this.user.set("mod_slow_mode", null);
          this.toasts.success({
            duration: 3000,
            data: {
              message: i18n("discourse_mod_categories.slow_mode.lifted"),
            },
          });
        } catch (error) {
          popupAjaxError(error);
        }
      },
    });
  }

  <template>
    {{#if this.show}}
      <section class="details mod-user-slow-mode">
        <div class="display-row {{if this.slowMode 'highlight-danger'}}">
          <div class="field">
            {{i18n "discourse_mod_categories.slow_mode.label"}}
          </div>
          <div class="value mod-user-slow-mode__status">{{this.status}}</div>
          <div class="controls">
            {{#if this.canSet}}
              <DButton
                class="btn-danger mod-user-slow-mode__set"
                @action={{this.openModal}}
                @icon="clock"
                @label={{if
                  this.slowMode
                  "discourse_mod_categories.slow_mode.change"
                  "discourse_mod_categories.slow_mode.set"
                }}
              />
              {{#if this.slowMode}}
                <DButton
                  class="btn-default mod-user-slow-mode__lift"
                  @action={{this.lift}}
                  @label="discourse_mod_categories.slow_mode.lift"
                />
              {{/if}}
            {{/if}}
          </div>
        </div>
      </section>
    {{/if}}
  </template>
}
