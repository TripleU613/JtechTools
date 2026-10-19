import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import type { ComponentLike } from "@glint/template";
import UntypedComboBox from "select-kit/components/combo-box";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import type ToastsService from "discourse/float-kit/services/toasts";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import icon from "discourse/helpers/d-icon";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Topic from "discourse/models/topic";
import { i18n } from "discourse-i18n";
import type { ChecklistItem } from "../lib/first-post-checklist.ts";
import { trustLevelOptions } from "../lib/trust-level-options.ts";

// Select-kit components are classic components with no Glint signature;
// this gives ComboBox one so `class` and the args used here type-check.
interface ComboBoxSignature {
  Element: HTMLElement;
  Args: {
    value: string;
    content: { id: string; name: string }[];
    onChange: (value: string) => void;
  };
}
const ComboBox = UntypedComboBox as unknown as ComponentLike<ComboBoxSignature>;

type PromptMode = "checklist" | "statement";
type PromptFrequency = "once" | "every_reply";

// The per-topic prompt as stored on the topic model.
interface TopicPromptChecklist {
  version: number;
  mode: PromptMode;
  statement: string;
  items: ChecklistItem[];
  frequency: PromptFrequency;
  max_tl: number;
  button_label: string;
  updated_at: string | null;
}

export type PromptChecklistTopic = Topic & {
  id: number;
  mod_topic_prompt_checklist?: TopicPromptChecklist | null;
  mod_topic_reply_prompt?: string | null;
  mod_topic_reply_prompt_max_tl?: number | string | null;
};

// GET/PUT/DELETE /discourse-mod-categories/topic/:id/prompt-checklist.json
interface PromptChecklistResponse {
  topic_id: number;
  version: number;
  mode: PromptMode;
  statement: string;
  items: ChecklistItem[];
  frequency: PromptFrequency;
  max_tl: number;
  button_label: string;
  updated_at: string | null;
  from_legacy: boolean;
}

interface ModTopicPromptChecklistModalSignature {
  Args: {
    model: { topic: PromptChecklistTopic };
    closeModal: () => void;
  };
}

// One editable row in the per-topic prompt checklist. Tracked so editing
// the label/url in place re-renders without rebuilding the whole list.
class ChecklistRow {
  @tracked label: string;
  @tracked url: string;

  constructor(label = "", url = "") {
    this.label = label;
    this.url = url;
  }
}

// Staff-facing modal opened from the topic admin (wrench) menu's
// "Prompt Checklist" entry. Lets a moderator add/edit/save the per-topic
// prompt. Mode picks between a single-message Statement and a multi-item
// Checklist; frequency picks between "once per user per topic" and "on
// every reply"; max_tl caps the audience by trust level. Saving bumps
// the version, re-prompting any user who already accepted an older one.
export default class ModTopicPromptChecklistModal extends Component<ModTopicPromptChecklistModalSignature> {
  @service declare toasts: ToastsService;

  @tracked rows: ChecklistRow[] = [];
  @tracked version = 0;
  @tracked buttonLabel = "";
  @tracked updatedAt: string | null = null;
  @tracked mode: PromptMode = "checklist";
  @tracked statement = "";
  @tracked frequency: PromptFrequency = "once";
  @tracked maxTl = "4";
  @tracked fromLegacy = false;
  @tracked loading = true;
  @tracked saving = false;

  frequencyOptions: { id: PromptFrequency; name: string }[] = [
    {
      id: "once",
      name: i18n(
        "discourse_mod_categories.topic_prompt_checklist.frequency_once"
      ),
    },
    {
      id: "every_reply",
      name: i18n(
        "discourse_mod_categories.topic_prompt_checklist.frequency_every_reply"
      ),
    },
  ];

  maxTlOptions = trustLevelOptions(true);

  constructor(
    owner: Owner,
    args: ModTopicPromptChecklistModalSignature["Args"]
  ) {
    super(owner, args);
    this.load();
  }

  get topic(): PromptChecklistTopic {
    return this.args.model.topic;
  }

  get lastRowIndex(): number {
    return this.rows.length - 1;
  }

  get isStatementMode(): boolean {
    return this.mode === "statement";
  }

  get isChecklistMode(): boolean {
    return this.mode === "checklist";
  }

  async load() {
    try {
      const result: PromptChecklistResponse = await ajax(
        `/discourse-mod-categories/topic/${this.topic.id}/prompt-checklist.json`
      );
      this.rows = (result.items || []).map(
        (item) => new ChecklistRow(item.label, item.url)
      );
      this.version = result.version || 0;
      this.buttonLabel = result.button_label || "";
      this.updatedAt = result.updated_at;
      this.mode = result.mode === "statement" ? "statement" : "checklist";
      this.statement = result.statement || "";
      this.frequency =
        result.frequency === "every_reply" ? "every_reply" : "once";
      this.maxTl = String(result.max_tl ?? 4);
      this.fromLegacy = !!result.from_legacy;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  @action
  addRow() {
    this.rows = [...this.rows, new ChecklistRow()];
  }

  @action
  removeRow(row: ChecklistRow) {
    this.rows = this.rows.filter((r) => r !== row);
  }

  @action
  updateLabel(row: ChecklistRow, event: Event) {
    row.label = (event.target as HTMLInputElement).value;
  }

  @action
  updateUrl(row: ChecklistRow, event: Event) {
    row.url = (event.target as HTMLInputElement).value;
  }

  @action
  updateButtonLabel(event: Event) {
    this.buttonLabel = (event.target as HTMLInputElement).value;
  }

  @action
  updateStatement(event: Event) {
    this.statement = (event.target as HTMLTextAreaElement).value;
  }

  @action
  updateMode(value: PromptMode) {
    this.mode = value;
  }

  @action
  updateFrequency(value: PromptFrequency) {
    this.frequency = value;
  }

  @action
  updateMaxTl(value: string) {
    this.maxTl = value;
  }

  @action
  async save() {
    this.saving = true;
    try {
      const result: PromptChecklistResponse = await ajax(
        `/discourse-mod-categories/topic/${this.topic.id}/prompt-checklist.json`,
        {
          type: "PUT",
          data: {
            mode: this.mode,
            statement: this.statement,
            items: this.rows.map((r) => ({ label: r.label, url: r.url })),
            frequency: this.frequency,
            max_tl: this.maxTl,
            button_label: this.buttonLabel,
          },
        }
      );
      this.version = result.version || 0;
      this.rows = (result.items || []).map(
        (item) => new ChecklistRow(item.label, item.url)
      );
      this.buttonLabel = result.button_label || "";
      this.updatedAt = result.updated_at;
      this.mode = result.mode === "statement" ? "statement" : "checklist";
      this.statement = result.statement || "";
      this.frequency =
        result.frequency === "every_reply" ? "every_reply" : "once";
      this.maxTl = String(result.max_tl ?? 4);
      this.fromLegacy = false;
      this.topic.set("mod_topic_prompt_checklist", {
        version: this.version,
        mode: this.mode,
        statement: this.statement,
        items: result.items || [],
        frequency: this.frequency,
        max_tl: parseInt(this.maxTl, 10) || 4,
        button_label: this.buttonLabel,
        updated_at: this.updatedAt,
      });
      // The new config supersedes the legacy reply-prompt fields, which
      // the server has cleared. Reflect that on the in-memory topic too
      // so the (now-removed) legacy gate stops reading stale data.
      this.topic.set("mod_topic_reply_prompt", null);
      this.topic.set("mod_topic_reply_prompt_max_tl", null);
      this.toasts.success({
        duration: 3000,
        data: {
          message: i18n(
            "discourse_mod_categories.topic_prompt_checklist.saved_toast"
          ),
        },
      });
      this.args.closeModal();
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  @action
  async clear() {
    this.saving = true;
    try {
      await ajax(
        `/discourse-mod-categories/topic/${this.topic.id}/prompt-checklist.json`,
        { type: "DELETE" }
      );
      this.rows = [];
      this.version = 0;
      this.buttonLabel = "";
      this.updatedAt = null;
      this.mode = "checklist";
      this.statement = "";
      this.frequency = "once";
      this.maxTl = "4";
      this.fromLegacy = false;
      this.topic.set("mod_topic_prompt_checklist", null);
      this.toasts.success({
        duration: 3000,
        data: {
          message: i18n(
            "discourse_mod_categories.topic_prompt_checklist.cleared_toast"
          ),
        },
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
      class="mod-topic-prompt-checklist-modal"
      @closeModal={{@closeModal}}
      @title={{i18n "discourse_mod_categories.topic_prompt_checklist.title"}}
    >
      <:body>
        {{#if this.loading}}
          <p class="mod-topic-prompt-checklist-loading">
            {{i18n "discourse_mod_categories.topic_prompt_checklist.loading"}}
          </p>
        {{else}}
          {{#if this.fromLegacy}}
            <div class="mod-topic-prompt-checklist-legacy-notice">
              {{i18n
                "discourse_mod_categories.topic_prompt_checklist.legacy_migration_notice"
              }}
            </div>
          {{/if}}

          {{#if this.version}}
            <p class="mod-checklist-meta">
              <span class="mod-checklist-version">
                {{i18n
                  "discourse_mod_categories.topic_prompt_checklist.current_version"
                  count=this.version
                }}
              </span>
              {{#if this.updatedAt}}
                <span class="mod-checklist-updated">
                  {{icon "clock-rotate-left"}}
                  {{ageWithTooltip this.updatedAt}}
                </span>
              {{/if}}
            </p>
          {{/if}}

          <div class="mod-checklist-field">
            <label class="mod-checklist-field-label">
              {{i18n
                "discourse_mod_categories.topic_prompt_checklist.mode_label"
              }}
            </label>
            <div class="mod-checklist-mode-toggle">
              <button
                class={{if this.isStatementMode "is-active"}}
                type="button"
                {{on "click" (fn this.updateMode "statement")}}
              >
                {{icon "align-left"}}
                <span class="mod-checklist-mode-toggle__title">
                  {{i18n
                    "discourse_mod_categories.topic_prompt_checklist.mode_title_statement"
                  }}
                </span>
              </button>
              <button
                class={{if this.isChecklistMode "is-active"}}
                type="button"
                {{on "click" (fn this.updateMode "checklist")}}
              >
                {{icon "list-check"}}
                <span class="mod-checklist-mode-toggle__title">
                  {{i18n
                    "discourse_mod_categories.topic_prompt_checklist.mode_title_checklist"
                  }}
                </span>
              </button>
            </div>
          </div>

          {{#if this.isStatementMode}}
            <div class="mod-checklist-field">
              <label class="mod-checklist-field-label">
                {{i18n
                  "discourse_mod_categories.topic_prompt_checklist.statement_label"
                }}
              </label>
              <textarea
                class="mod-topic-prompt-checklist-statement"
                placeholder={{i18n
                  "discourse_mod_categories.topic_prompt_checklist.statement_placeholder"
                }}
                rows="4"
                value={{this.statement}}
                {{on "input" this.updateStatement}}
              ></textarea>
            </div>
          {{else}}
            {{#if this.rows.length}}
              <div class="mod-checklist-rows">
                {{#each this.rows as |row|}}
                  <div class="mod-checklist-row">
                    <input
                      class="mod-checklist-row-label"
                      placeholder={{i18n
                        "discourse_mod_categories.topic_prompt_checklist.item_label"
                      }}
                      type="text"
                      value={{row.label}}
                      {{on "input" (fn this.updateLabel row)}}
                    />
                    <input
                      class="mod-checklist-row-url"
                      placeholder={{i18n
                        "discourse_mod_categories.topic_prompt_checklist.item_url"
                      }}
                      type="text"
                      value={{row.url}}
                      {{on "input" (fn this.updateUrl row)}}
                    />
                    <DButton
                      class="btn-flat mod-checklist-remove"
                      @action={{fn this.removeRow row}}
                      @icon="trash-can"
                      @title="discourse_mod_categories.topic_prompt_checklist.remove_item"
                    />
                  </div>
                {{/each}}
              </div>
            {{/if}}
            <button
              class="mod-checklist-add-inline"
              type="button"
              {{on "click" this.addRow}}
            >
              {{icon "plus"}}
              {{i18n
                "discourse_mod_categories.topic_prompt_checklist.add_item"
              }}
            </button>
          {{/if}}

          <div class="mod-checklist-field-grid">
            <div class="mod-checklist-field">
              <label class="mod-checklist-field-label">
                {{i18n
                  "discourse_mod_categories.topic_prompt_checklist.frequency_label"
                }}
              </label>
              <ComboBox
                class="mod-topic-prompt-checklist-frequency"
                @content={{this.frequencyOptions}}
                @onChange={{this.updateFrequency}}
                @value={{this.frequency}}
              />
            </div>

            <div class="mod-checklist-field">
              <label class="mod-checklist-field-label">
                {{i18n
                  "discourse_mod_categories.topic_prompt_checklist.max_tl_label"
                }}
              </label>
              <ComboBox
                class="mod-topic-prompt-checklist-max-tl"
                @content={{this.maxTlOptions}}
                @onChange={{this.updateMaxTl}}
                @value={{this.maxTl}}
              />
            </div>
          </div>

          <div class="mod-checklist-field">
            <label class="mod-checklist-field-label">
              {{i18n
                "discourse_mod_categories.topic_prompt_checklist.button_label_label"
              }}
            </label>
            <input
              class="mod-topic-prompt-checklist-button-label"
              placeholder={{i18n
                "discourse_mod_categories.topic_prompt_checklist.button_label_placeholder"
              }}
              type="text"
              value={{this.buttonLabel}}
              {{on "input" this.updateButtonLabel}}
            />
          </div>
        {{/if}}
      </:body>

      <:footer>
        <DButton
          class="btn-primary mod-topic-prompt-checklist-save"
          @action={{this.save}}
          @disabled={{this.saving}}
          @label="discourse_mod_categories.topic_prompt_checklist.save"
        />
        {{#if this.version}}
          <DButton
            class="btn-danger mod-topic-prompt-checklist-clear"
            @action={{this.clear}}
            @disabled={{this.saving}}
            @icon="trash-can"
            @label="discourse_mod_categories.topic_prompt_checklist.clear"
          />
        {{/if}}
        <DButton
          class="btn-flat"
          @action={{@closeModal}}
          @label="discourse_mod_categories.topic_prompt_checklist.cancel"
        />
      </:footer>
    </DModal>
  </template>
}
