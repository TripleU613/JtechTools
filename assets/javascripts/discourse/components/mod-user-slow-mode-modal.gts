import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action, get } from "@ember/object";
import { service } from "@ember/service";
import { eq, not } from "truth-helpers";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import type ToastsService from "discourse/float-kit/services/toasts";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import {
  type SlowModeAdminSummary,
  slowModeInterval,
} from "../lib/mod-slow-mode.ts";

// The admin page's user, a classic Ember object.
export interface SlowModeAdminUser {
  id: number;
  username: string;
  admin?: boolean;
  moderator?: boolean;
  mod_slow_mode?: SlowModeAdminSummary | null;
  can_set_mod_slow_mode?: boolean;
  set: (key: string, value: unknown) => void;
}

interface ModUserSlowModeModalSignature {
  Args: {
    model: { user: SlowModeAdminUser };
    closeModal: () => void;
  };
}

const INTERVALS = [300, 900, 3600, 21600, 86400];
const DURATIONS: Record<string, number> = {
  day: 86400000,
  week: 7 * 86400000,
  month: 30 * 86400000,
};
const MAX_MINUTES = 7 * 24 * 60;

// "2026-11-05T14:30" for a datetime-local input, in the browser's time zone.
function localInputValue(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(
    date.getDate()
  )}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

export default class ModUserSlowModeModal extends Component<ModUserSlowModeModalSignature> {
  @service declare toasts: ToastsService;

  @tracked interval = this.initialInterval();
  @tracked customMinutes = this.initialCustomMinutes();
  @tracked duration = this.current?.ends_at ? "custom" : "week";
  @tracked until = this.current?.ends_at
    ? localInputValue(new Date(this.current.ends_at))
    : "";
  @tracked reason = "";
  @tracked saving = false;

  intervals = INTERVALS.map((seconds) => ({
    value: String(seconds),
    label: slowModeInterval(seconds),
  }));

  get user(): SlowModeAdminUser {
    return this.args.model.user;
  }

  get current(): SlowModeAdminSummary | null {
    return get(this.args.model.user, "mod_slow_mode") ?? null;
  }

  get seconds(): number | null {
    if (this.interval !== "custom") {
      return Number(this.interval);
    }
    const minutes = Number(this.customMinutes);
    if (!Number.isInteger(minutes) || minutes < 1 || minutes > MAX_MINUTES) {
      return null;
    }
    return minutes * 60;
  }

  // null for no end; undefined when the date picked can't be used.
  get endsAt(): string | null | undefined {
    if (this.duration === "forever") {
      return null;
    }
    if (this.duration === "custom") {
      const date = this.until ? new Date(this.until) : null;
      if (!date || isNaN(date.getTime()) || date.getTime() <= Date.now()) {
        return undefined;
      }
      return date.toISOString();
    }
    return new Date(Date.now() + DURATIONS[this.duration]).toISOString();
  }

  get canSave(): boolean {
    return (
      !this.saving &&
      this.seconds !== null &&
      this.endsAt !== undefined &&
      this.reason.trim().length > 0
    );
  }

  initialInterval(): string {
    const seconds = this.current?.seconds;
    if (!seconds) {
      return "900";
    }
    return INTERVALS.includes(seconds) ? String(seconds) : "custom";
  }

  initialCustomMinutes(): string {
    const seconds = this.current?.seconds;
    return seconds && !INTERVALS.includes(seconds) ? String(seconds / 60) : "";
  }

  @action
  setInterval(event: Event) {
    this.interval = (event.target as HTMLSelectElement).value;
  }

  @action
  setCustomMinutes(event: Event) {
    this.customMinutes = (event.target as HTMLInputElement).value;
  }

  @action
  setDuration(event: Event) {
    this.duration = (event.target as HTMLSelectElement).value;
  }

  @action
  setUntil(event: Event) {
    this.until = (event.target as HTMLInputElement).value;
  }

  @action
  setReason(event: Event) {
    this.reason = (event.target as HTMLTextAreaElement).value;
  }

  @action
  async save() {
    if (!this.canSave) {
      return;
    }
    this.saving = true;
    try {
      const result: { slow_mode: SlowModeAdminSummary } = await ajax(
        `/discourse-mod-categories/user/${this.user.id}/slow-mode`,
        {
          type: "PUT",
          data: {
            seconds: this.seconds,
            ends_at: this.endsAt ?? "",
            reason: this.reason.trim(),
          },
        }
      );
      this.user.set("mod_slow_mode", result.slow_mode);
      this.toasts.success({
        duration: 3000,
        data: { message: i18n("discourse_mod_categories.slow_mode.saved") },
      });
      this.args.closeModal();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  <template>
    <DModal
      class="mod-user-slow-mode-modal"
      @closeModal={{@closeModal}}
      @title={{i18n
        "discourse_mod_categories.slow_mode.modal.title"
        username=this.user.username
      }}
    >
      <:body>
        <div class="control-group">
          <label class="mod-messages-label" for="mod-slow-mode-interval">
            {{i18n "discourse_mod_categories.slow_mode.modal.interval"}}
          </label>
          <select
            id="mod-slow-mode-interval"
            class="mod-slow-mode-interval"
            {{on "change" this.setInterval}}
          >
            {{#each this.intervals as |choice|}}
              <option
                value={{choice.value}}
                selected={{eq choice.value this.interval}}
              >{{choice.label}}</option>
            {{/each}}
            <option value="custom" selected={{eq this.interval "custom"}}>
              {{i18n
                "discourse_mod_categories.slow_mode.modal.custom_interval"
              }}
            </option>
          </select>
          {{#if (eq this.interval "custom")}}
            <label class="mod-messages-label" for="mod-slow-mode-minutes">
              {{i18n "discourse_mod_categories.slow_mode.modal.custom_minutes"}}
            </label>
            <input
              id="mod-slow-mode-minutes"
              class="mod-slow-mode-minutes"
              type="number"
              min="1"
              max={{MAX_MINUTES}}
              step="1"
              value={{this.customMinutes}}
              {{on "input" this.setCustomMinutes}}
            />
          {{/if}}
        </div>

        <div class="control-group">
          <label class="mod-messages-label" for="mod-slow-mode-duration">
            {{i18n "discourse_mod_categories.slow_mode.modal.duration"}}
          </label>
          <select
            id="mod-slow-mode-duration"
            class="mod-slow-mode-duration"
            {{on "change" this.setDuration}}
          >
            <option value="day" selected={{eq this.duration "day"}}>
              {{i18n "discourse_mod_categories.slow_mode.modal.day"}}
            </option>
            <option value="week" selected={{eq this.duration "week"}}>
              {{i18n "discourse_mod_categories.slow_mode.modal.week"}}
            </option>
            <option value="month" selected={{eq this.duration "month"}}>
              {{i18n "discourse_mod_categories.slow_mode.modal.month"}}
            </option>
            <option value="forever" selected={{eq this.duration "forever"}}>
              {{i18n "discourse_mod_categories.slow_mode.modal.forever"}}
            </option>
            <option value="custom" selected={{eq this.duration "custom"}}>
              {{i18n "discourse_mod_categories.slow_mode.modal.custom_date"}}
            </option>
          </select>
          {{#if (eq this.duration "custom")}}
            <label class="mod-messages-label" for="mod-slow-mode-until">
              {{i18n "discourse_mod_categories.slow_mode.modal.until"}}
            </label>
            <input
              id="mod-slow-mode-until"
              class="mod-slow-mode-until"
              type="datetime-local"
              value={{this.until}}
              {{on "input" this.setUntil}}
            />
          {{/if}}
        </div>

        <div class="control-group">
          <label class="mod-messages-label" for="mod-slow-mode-reason">
            {{i18n "discourse_mod_categories.slow_mode.modal.reason"}}
          </label>
          <textarea
            id="mod-slow-mode-reason"
            class="mod-slow-mode-reason"
            rows="3"
            maxlength="1000"
            value={{this.reason}}
            {{on "input" this.setReason}}
          ></textarea>
        </div>
      </:body>

      <:footer>
        <DButton
          class="btn-primary mod-slow-mode-save"
          @action={{this.save}}
          @disabled={{not this.canSave}}
          @label="discourse_mod_categories.slow_mode.modal.save"
        />
        <DButton
          class="btn-flat"
          @action={{@closeModal}}
          @label="discourse_mod_categories.slow_mode.modal.cancel"
        />
      </:footer>
    </DModal>
  </template>
}
