import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import { htmlSafe, type TrustedHTML } from "@ember/template";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { cook } from "discourse/lib/text";
import { i18n } from "discourse-i18n";
import type {
  ChecklistItem,
  ChecklistUser,
  OwedChecklist,
} from "../lib/first-post-checklist.ts";

interface ModFirstPostChecklistSignature {
  Args: {
    model: {
      checklist: OwedChecklist;
      onAccept: () => void;
      onCancel: () => void;
    };
    closeModal: () => void;
  };
}

// Modal shown to a user who owes an acknowledgement before posting. Two
// shapes are supported:
//   - "checklist" (the historical default): every item must be ticked
//     before the accept button is enabled.
//   - "statement" (per-topic only): a single Markdown-cooked message and
//     an accept button that is enabled immediately. Replaces the legacy
//     per-topic before-reply prompt.
// Accepting records the checklist version on the user so it is not shown
// again until staff edit the list. Closing without accepting rejects,
// aborting the composer save.
export default class ModFirstPostChecklist extends Component<ModFirstPostChecklistSignature> {
  @service declare currentUser: ChecklistUser | null;

  @tracked checkedKeys = new Set<number>();
  @tracked saving = false;
  @tracked cookedStatement: string | null = null;
  accepted = false;

  isChecked = (index: number): boolean => this.checkedKeys.has(index);

  constructor(owner: Owner, args: ModFirstPostChecklistSignature["Args"]) {
    super(owner, args);
    if (this.isStatementMode) {
      this.cookStatement();
    }
  }

  get checklist(): OwedChecklist {
    return this.args.model.checklist;
  }

  get isStatementMode(): boolean {
    return this.checklist?.mode === "statement";
  }

  get items(): ChecklistItem[] {
    return this.checklist.items || [];
  }

  get allChecked(): boolean {
    if (this.isStatementMode) {
      return true;
    }
    return this.checkedKeys.size >= this.items.length;
  }

  get progressLabel(): string {
    if (this.checkedKeys.size >= this.items.length) {
      return i18n("discourse_mod_categories.first_post_checklist.all_done");
    }
    return i18n("discourse_mod_categories.first_post_checklist.progress", {
      checked: this.checkedKeys.size,
      total: this.items.length,
    });
  }

  get progressStyle() {
    const total = this.items.length || 1;
    const percent = Math.round((this.checkedKeys.size / total) * 100);
    return htmlSafe(`width:${percent}%`);
  }

  get disableConfirm(): boolean {
    return this.saving || !this.allChecked;
  }

  // Staff-configured accept-button text, falling back to the default.
  get confirmLabel(): string {
    return (
      this.checklist.button_label ||
      i18n("discourse_mod_categories.first_post_checklist.confirm")
    );
  }

  async cookStatement() {
    const raw = (this.checklist.statement || "").trim();
    if (!raw) {
      this.cookedStatement = null;
      return;
    }
    try {
      const cooked: TrustedHTML = await cook(raw, undefined);
      this.cookedStatement = String(cooked);
    } catch {
      this.cookedStatement = null;
    }
  }

  @action
  toggle(index: number) {
    const next = new Set(this.checkedKeys);
    if (next.has(index)) {
      next.delete(index);
    } else {
      next.add(index);
    }
    this.checkedKeys = next;
  }

  @action
  async confirm() {
    this.saving = true;

    try {
      await ajax("/discourse-mod-categories/checklist/accept", {
        type: "POST",
        data: {
          version: this.checklist.version,
          kind: this.checklist.kind || "global",
          id: this.checklist.id,
        },
      });
      this.accepted = true;
      this.currentUser?.set("mod_first_post_checklist", null);
      this.args.model.onAccept();
      this.args.closeModal();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  // Closing the modal any other way (X button, backdrop) counts as a
  // cancel, which aborts the post.
  @action
  handleClose() {
    if (!this.accepted) {
      this.args.model.onCancel();
    }
    this.args.closeModal();
  }

  <template>
    <DModal
      class="mod-first-post-checklist-modal"
      @closeModal={{this.handleClose}}
      @title={{i18n
        "discourse_mod_categories.first_post_checklist.modal_title"
      }}
    >
      <:body>
        {{#if this.isStatementMode}}
          {{#if this.cookedStatement}}
            <div class="mod-checklist-statement cooked">
              {{htmlSafe this.cookedStatement}}
            </div>
          {{else}}
            <div class="mod-checklist-statement">
              {{this.checklist.statement}}
            </div>
          {{/if}}
          {{#if this.checklist.updated_at}}
            <p class="mod-checklist-updated-at">
              {{icon "clock-rotate-left"}}
              {{i18n
                "discourse_mod_categories.first_post_checklist.last_updated"
              }}
              {{ageWithTooltip this.checklist.updated_at}}
            </p>
          {{/if}}
        {{else}}
          <div class="mod-checklist-progress {{if this.allChecked 'is-done'}}">
            <div class="mod-checklist-progress__bar">
              <span style={{this.progressStyle}}></span>
            </div>
            <span class="mod-checklist-progress__count">
              {{#if this.allChecked}}{{icon "check"}}{{/if}}
              {{this.progressLabel}}
            </span>
          </div>
          <ul class="mod-checklist-items">
            {{#each this.items as |item index|}}
              <li
                class="mod-checklist-item
                  {{if (this.isChecked index) 'is-checked'}}"
              >
                <label class="mod-checklist-item-label">
                  <input
                    checked={{this.isChecked index}}
                    class="mod-checklist-checkbox"
                    type="checkbox"
                    {{on "change" (fn this.toggle index)}}
                  />
                  <span aria-hidden="true" class="mod-checklist-indicator">
                    {{icon "check"}}
                  </span>
                  <span class="mod-checklist-text">{{item.label}}</span>
                </label>
                {{#if item.url}}
                  <a
                    class="mod-checklist-link"
                    href={{item.url}}
                    rel="noopener noreferrer"
                    target="_blank"
                  >
                    {{icon "up-right-from-square"}}
                    {{i18n
                      "discourse_mod_categories.first_post_checklist.open_link"
                    }}
                  </a>
                {{/if}}
              </li>
            {{/each}}
          </ul>
          {{#if this.checklist.updated_at}}
            <p class="mod-checklist-updated-at">
              {{icon "clock-rotate-left"}}
              {{i18n
                "discourse_mod_categories.first_post_checklist.last_updated"
              }}
              {{ageWithTooltip this.checklist.updated_at}}
            </p>
          {{/if}}
        {{/if}}
      </:body>

      <:footer>
        <DButton
          class="btn-primary mod-checklist-confirm"
          @action={{this.confirm}}
          @disabled={{this.disableConfirm}}
          @translatedLabel={{this.confirmLabel}}
        />
        <DButton
          class="btn-flat"
          @action={{this.handleClose}}
          @label="discourse_mod_categories.first_post_checklist.cancel"
        />
      </:footer>
    </DModal>
  </template>
}
