import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type { SafeString } from "@ember/template";
import type { ComponentLike } from "@glint/template";
import UntypedComboBox from "select-kit/components/combo-box";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Category from "discourse/models/category";
import { i18n } from "discourse-i18n";
import { messageToHtml } from "../../lib/linkify-message.ts";
import {
  type TrustLevelOption,
  trustLevelOptions,
} from "../../lib/trust-level-options.ts";

// Select-kit components are classic components with no Glint signature;
// this gives ComboBox one so `class` and the args used here type-check.
interface ComboBoxSignature {
  Element: HTMLElement;
  Args: {
    value: string;
    content: TrustLevelOption[];
    onChange: (value: string) => void;
  };
}
const ComboBox = UntypedComboBox as unknown as ComponentLike<ComboBoxSignature>;

type PromptCategory = Category & {
  id: number;
  mod_category_new_topic_prompt?: string | null;
  mod_category_new_topic_prompt_max_tl?: number | string | null;
};

interface NewTopicPromptResponse {
  new_topic_prompt: string;
  new_topic_prompt_max_tl: number | string | null;
}

interface ModNewTopicPromptSignature {
  Args: { outletArgs: { category: PromptCategory } };
}

// Field on the category edit screen letting a moderator set the
// "before you post a new topic" prompt for that category. Saves through
// the Guardian-gated plugin endpoint. Only rendered for existing
// categories (a new, unsaved category has no id).
export default class ModNewTopicPrompt extends Component<ModNewTopicPromptSignature> {
  static shouldRender(
    args: { category?: { id?: number } | null } | null | undefined,
    context:
      | {
          siteSettings?: {
            mod_categories_enabled?: boolean;
            precheck_new_topic_enabled?: boolean;
          };
        }
      | null
      | undefined
  ): boolean {
    if (
      !context?.siteSettings?.mod_categories_enabled ||
      !context?.siteSettings?.precheck_new_topic_enabled
    ) {
      return false;
    }
    return !!(args && args.category && args.category.id);
  }

  @tracked prompt = this.category.mod_category_new_topic_prompt || "";

  @tracked maxTl = String(
    this.category.mod_category_new_topic_prompt_max_tl ?? 4
  );

  @tracked saving = false;
  @tracked saved = false;
  audienceOptions = trustLevelOptions(true);

  get category(): PromptCategory {
    return this.args.outletArgs.category;
  }

  // Live preview of how the prompt will look in the confirmation dialog.
  get previewHtml(): SafeString {
    return messageToHtml(this.prompt);
  }

  @action
  updatePrompt(event: Event) {
    this.prompt = (event.target as HTMLTextAreaElement).value;
    this.saved = false;
  }

  @action
  updateMaxTl(value: string) {
    this.maxTl = value;
    this.saved = false;
  }

  @action
  async save() {
    this.saving = true;

    try {
      const result: NewTopicPromptResponse = await ajax(
        `/discourse-mod-categories/category/${this.category.id}`,
        {
          type: "PUT",
          data: {
            new_topic_prompt: this.prompt,
            new_topic_prompt_max_tl: this.maxTl,
          },
        }
      );

      this.category.set(
        "mod_category_new_topic_prompt",
        result.new_topic_prompt
      );
      this.category.set(
        "mod_category_new_topic_prompt_max_tl",
        result.new_topic_prompt_max_tl
      );
      this.saved = true;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.saving = false;
    }
  }

  <template>
    <section class="mod-new-topic-prompt field">
      <label class="mod-messages-label">
        {{i18n
          "discourse_mod_categories.category_settings.new_topic_prompt_label"
        }}
      </label>
      <textarea
        class="mod-new-topic-prompt-input"
        rows="3"
        value={{this.prompt}}
        {{on "input" this.updatePrompt}}
      ></textarea>

      {{#if this.prompt}}
        <div class="mod-prompt-preview">
          <span class="mod-prompt-preview-label">
            {{i18n "discourse_mod_categories.category_settings.preview_label"}}
          </span>
          <div class="mod-prompt-preview-body">{{this.previewHtml}}</div>
        </div>
      {{/if}}

      <label class="mod-messages-label">
        {{i18n "discourse_mod_categories.audience.label"}}
      </label>
      <ComboBox
        class="mod-new-topic-audience-input"
        @content={{this.audienceOptions}}
        @onChange={{this.updateMaxTl}}
        @value={{this.maxTl}}
      />

      <div class="mod-new-topic-prompt-actions">
        <DButton
          class="btn-primary mod-save-new-topic-prompt"
          @action={{this.save}}
          @disabled={{this.saving}}
          @label="discourse_mod_categories.category_settings.save"
        />
        {{#if this.saved}}
          <span class="mod-saved-indicator">
            {{i18n "discourse_mod_categories.category_settings.saved"}}
          </span>
        {{/if}}
      </div>
    </section>
  </template>
}
