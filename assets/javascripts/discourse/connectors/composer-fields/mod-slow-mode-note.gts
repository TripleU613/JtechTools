import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import type AppEventsService from "discourse/services/app-events";
import { i18n } from "discourse-i18n";
import {
  type SlowModeSummary,
  slowModeInterval,
  slowModeWait,
} from "../../lib/mod-slow-mode.ts";

interface SlowModeComposer {
  creatingTopic?: boolean;
  replyingToTopic?: boolean;
  editingPost?: boolean;
  privateMessage?: boolean;
}

interface SlowModeCurrentUser {
  mod_slow_mode?: SlowModeSummary | null;
}

interface ModSlowModeNoteSignature {
  Args: { outletArgs: { model?: SlowModeComposer | null } };
}

// Tells a user in slow mode, before they write, how often they can post and
// how long until the next one. Private messages and edits aren't limited, so
// it stays out of those composers.
export default class ModSlowModeNote extends Component<ModSlowModeNoteSignature> {
  @service declare appEvents: AppEventsService;
  @service declare currentUser: SlowModeCurrentUser | null;

  @tracked slowMode: SlowModeSummary | null = null;
  @tracked now = Date.now();

  #interval: number | null = null;

  constructor(owner: Owner, args: ModSlowModeNoteSignature["Args"]) {
    super(owner, args);
    this.slowMode = this.currentUser?.mod_slow_mode ?? null;
    this.appEvents.on("composer:saved", this, this.refresh);
    this.startCountdown();
  }

  willDestroy() {
    super.willDestroy();
    this.appEvents.off("composer:saved", this, this.refresh);
    this.stopCountdown();
  }

  get show(): boolean {
    const composer = this.args.outletArgs?.model;
    if (!this.slowMode || !composer) {
      return false;
    }
    if (composer.privateMessage || composer.editingPost) {
      return false;
    }
    return !!(composer.creatingTopic || composer.replyingToTopic);
  }

  get interval(): string {
    return this.slowMode ? slowModeInterval(this.slowMode.seconds) : "";
  }

  // "8 minutes" while they have to wait, else null.
  get waitText(): string | null {
    const next = this.slowMode?.next_post_at;
    const waitMs = next ? new Date(next).getTime() - this.now : 0;
    return waitMs > 0 ? slowModeWait(waitMs) : null;
  }

  // Only while there's a wait to count down; every 30 seconds is enough for
  // a wait counted in minutes. A plain interval, not the run loop, so it
  // never holds up anything waiting for the page to settle.
  startCountdown() {
    this.stopCountdown();
    this.now = Date.now();
    if (!this.waitText) {
      return;
    }
    this.#interval = window.setInterval(() => {
      this.now = Date.now();
      if (!this.waitText) {
        this.stopCountdown();
      }
    }, 30000);
  }

  stopCountdown() {
    if (this.#interval !== null) {
      window.clearInterval(this.#interval);
      this.#interval = null;
    }
  }

  // A post just went through, or into the review queue: ask the server
  // rather than guess, since it knows whether it counted.
  async refresh() {
    if (!this.slowMode) {
      return;
    }
    try {
      const result: { slow_mode: SlowModeSummary | null } = await ajax(
        "/discourse-mod-categories/slow-mode"
      );
      this.slowMode = result.slow_mode;
      if (this.currentUser) {
        this.currentUser.mod_slow_mode = result.slow_mode;
      }
      this.startCountdown();
    } catch {
      // The note is a courtesy; the server still enforces the limit.
    }
  }

  <template>
    {{#if this.show}}
      <div class="mod-slow-mode-note" role="status">
        {{icon "clock"}}
        <span>
          {{i18n
            "discourse_mod_categories.slow_mode.composer.note"
            interval=this.interval
          }}
          {{#if this.slowMode.waiting}}
            {{i18n "discourse_mod_categories.slow_mode.composer.waiting"}}
          {{else if this.waitText}}
            {{i18n
              "discourse_mod_categories.slow_mode.composer.wait"
              time=this.waitText
            }}
          {{/if}}
        </span>
      </div>
    {{/if}}
  </template>
}
