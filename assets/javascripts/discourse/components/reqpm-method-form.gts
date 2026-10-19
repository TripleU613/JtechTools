import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { not } from "truth-helpers";
import DButton from "discourse/components/d-button";
import EmojiPicker from "discourse/components/emoji-picker";
import { i18n } from "discourse-i18n";
import {
  CUSTOM,
  kindInfo,
  type ReqpmKindId,
  type ReqpmKindInfo,
} from "../lib/reqpm-kinds.ts";
import ReqpmService, {
  reqpmError,
  ReqpmMethodAttrs,
  ReqpmOwnMethod,
  ReqpmSiteSettings,
} from "../services/reqpm.ts";
import ReqpmKindIcon from "./reqpm-kind-icon.gts";

interface ReqpmMethodFormSignature {
  Args: {
    // Editing an existing method, or adding a new one of `kind`.
    method?: ReqpmOwnMethod | null;
    kind?: ReqpmKindId | null;
    onSaved?: (method: ReqpmOwnMethod) => void;
    onCancel: () => void;
  };
}

// Add or edit one way to reach you. The input adapts to the kind (a phone
// keypad for numbers, email keyboard for email, …); custom ones also get a
// name and an emoji. The server does the real validation and its message is
// shown next to the field it is about.
export default class ReqpmMethodForm extends Component<ReqpmMethodFormSignature> {
  @service declare reqpm: ReqpmService;
  @service declare siteSettings: ReqpmSiteSettings;

  @tracked value = this.args.method?.value || "";
  @tracked label = this.args.method?.label || "";
  @tracked emoji = this.args.method?.emoji || "wave";
  @tracked note = this.args.method?.note || "";
  @tracked
  shareByDefault = this.args.method ? this.args.method.share_by_default : true;
  @tracked saving = false;
  @tracked error: string | null = null;
  @tracked errorField: string | null = null;

  fieldClass = (field: string): string =>
    this.errorField === field
      ? "reqpm-field reqpm-field--error"
      : "reqpm-field";

  get kind(): ReqpmKindId {
    return this.args.method?.kind || this.args.kind;
  }

  get info(): ReqpmKindInfo {
    return kindInfo(this.kind);
  }

  get isCustom(): boolean {
    return this.kind === CUSTOM;
  }

  get kindName(): string {
    return i18n(`reqpm.kinds.${this.kind}.name`);
  }

  get fieldLabel(): string {
    return i18n(`reqpm.kinds.${this.kind}.field`);
  }

  get placeholder(): string {
    return i18n(`reqpm.kinds.${this.kind}.placeholder`);
  }

  // Phone numbers without a country code get the forum's default one; the
  // only hint the form shows.
  get hint(): string | null {
    return this.info.input === "tel"
      ? i18n("reqpm.form.country_code_hint", {
          code: this.siteSettings.reqpm_default_country_code || "1",
        })
      : null;
  }

  get canSave(): boolean {
    return (
      !this.saving &&
      this.value.trim().length > 0 &&
      (!this.isCustom || this.label.trim().length > 0)
    );
  }

  get isEdit(): boolean {
    return !!this.args.method;
  }

  @action
  setValue(event: Event) {
    this.value = (event.target as HTMLInputElement).value;
  }

  @action
  setLabel(event: Event) {
    this.label = (event.target as HTMLInputElement).value;
  }

  @action
  setNote(event: Event) {
    this.note = (event.target as HTMLInputElement).value;
  }

  @action
  setEmoji(emoji: string) {
    this.emoji = emoji;
  }

  @action
  toggleDefault(event: Event) {
    this.shareByDefault = (event.target as HTMLInputElement).checked;
  }

  @action
  async save(event?: Event) {
    event?.preventDefault();
    if (!this.canSave) {
      return;
    }
    this.saving = true;
    this.error = null;
    this.errorField = null;

    const attrs: ReqpmMethodAttrs = {
      kind: this.kind,
      value: this.value.trim(),
      note: this.note.trim(),
      share_by_default: this.shareByDefault,
    };
    if (this.isCustom) {
      attrs.label = this.label.trim();
      attrs.emoji = this.emoji;
    }

    try {
      const result = this.isEdit
        ? await this.reqpm.updateMethod(this.args.method.id, attrs)
        : await this.reqpm.addMethod(attrs);
      this.args.onSaved?.(result.method);
    } catch (e) {
      const { message, field } = reqpmError(e);
      this.error = message || i18n("reqpm.errors.generic");
      this.errorField = field || "value";
    } finally {
      this.saving = false;
    }
  }

  <template>
    <form class="reqpm-method-form" {{on "submit" this.save}}>
      <div class="reqpm-method-form__head">
        <ReqpmKindIcon @emoji={{this.emoji}} @kind={{this.kind}} />
        <span class="reqpm-method-form__kind">{{this.kindName}}</span>
      </div>

      {{#if this.isCustom}}
        <div class="reqpm-method-form__row">
          <div class={{this.fieldClass "emoji"}}>
            <span class="reqpm-field__label">{{i18n "reqpm.form.emoji"}}</span>
            <EmojiPicker
              @btnClass="btn-default reqpm-method-form__emoji"
              @context="reqpm"
              @didSelectEmoji={{this.setEmoji}}
              @emoji={{this.emoji}}
              @modalForMobile={{true}}
            />
          </div>
          <label class="{{this.fieldClass 'label'}} reqpm-field--grow">
            <span class="reqpm-field__label">{{i18n "reqpm.form.label"}}</span>
            <input
              maxlength="30"
              placeholder={{i18n "reqpm.form.label_placeholder"}}
              type="text"
              value={{this.label}}
              {{on "input" this.setLabel}}
            />
          </label>
        </div>
      {{/if}}

      <label class={{this.fieldClass "value"}}>
        <span class="reqpm-field__label">{{this.fieldLabel}}</span>
        <input
          autocomplete="off"
          class="reqpm-method-form__value"
          inputmode={{this.info.inputmode}}
          maxlength="200"
          placeholder={{this.placeholder}}
          type={{this.info.input}}
          value={{this.value}}
          {{on "input" this.setValue}}
        />
        {{#if this.hint}}
          <span class="reqpm-field__hint">{{this.hint}}</span>
        {{/if}}
      </label>

      <label class={{this.fieldClass "note"}}>
        <span class="reqpm-field__label">{{i18n "reqpm.form.note"}}
          <span class="reqpm-field__optional">{{i18n
              "reqpm.form.optional"
            }}</span></span>
        <input
          maxlength="80"
          placeholder={{i18n "reqpm.form.note_placeholder"}}
          type="text"
          value={{this.note}}
          {{on "input" this.setNote}}
        />
      </label>

      <label class="reqpm-method-form__default">
        <input
          checked={{this.shareByDefault}}
          type="checkbox"
          {{on "change" this.toggleDefault}}
        />
        {{i18n "reqpm.form.share_by_default"}}
      </label>

      {{#if this.error}}
        <div class="reqpm-method-form__error" role="alert">{{this.error}}</div>
      {{/if}}

      <div class="reqpm-method-form__buttons">
        <DButton
          class="btn-primary btn-small"
          @action={{this.save}}
          @disabled={{not this.canSave}}
          @icon="check"
          @isLoading={{this.saving}}
          @label={{if this.isEdit "reqpm.form.save" "reqpm.form.add"}}
        />
        <DButton
          class="btn-flat btn-small"
          @action={{@onCancel}}
          @label="reqpm.form.cancel"
        />
      </div>
    </form>
  </template>
}
