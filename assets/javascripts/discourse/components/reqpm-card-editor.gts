import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import DButton from "discourse/components/d-button";
import type DialogService from "discourse/dialog-holder/services/dialog";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import { KINDS, type ReqpmKindId } from "../lib/reqpm-kinds.ts";
import ReqpmService, { ReqpmCard, ReqpmOwnMethod } from "../services/reqpm.ts";
import ReqpmKindIcon from "./reqpm-kind-icon.gts";
import ReqpmMethodForm from "./reqpm-method-form.gts";

const isLast = (index: number, length: number): boolean => index === length - 1;

type ReqpmEditing =
  | null
  | "pick"
  | { kind: ReqpmKindId; method?: undefined }
  | { method: ReqpmOwnMethod; kind?: undefined };

interface ReqpmCardEditorSignature {
  Args: {
    // Open straight on the "add" picker when the card is empty.
    startAdding?: boolean;
    onChange?: (card: ReqpmCard) => void;
  };
}

// The signed-in user's own contact card: the ways they can be reached, in
// the order they want them shown. Picking "add" shows a grid of platforms
// (phone, WhatsApp, email, … and "Custom" with your own name and emoji);
// picking one opens a small form for just that value.
export default class ReqpmCardEditor extends Component<ReqpmCardEditorSignature> {
  @service declare reqpm: ReqpmService;
  @service declare dialog: DialogService;

  @tracked methods: ReqpmOwnMethod[] = [];
  @tracked max = 10;
  @tracked loading = true;
  // null | "pick" | { kind } | { method }
  @tracked editing: ReqpmEditing = null;

  nameFor = (method: ReqpmOwnMethod): string | null =>
    method.kind === "custom"
      ? method.label
      : i18n(`reqpm.kinds.${method.kind}.name`);

  constructor(owner: Owner, args: ReqpmCardEditorSignature["Args"]) {
    super(owner, args);
    this.load();
  }

  get canAdd(): boolean {
    return this.methods.length < this.max;
  }

  get isPicking(): boolean {
    return this.editing === "pick";
  }

  // On first run (setup prompt, empty card in the per-user window) the
  // picker is the whole point — there is nothing to go back to.
  get pickerCancellable(): boolean {
    return !(this.args.startAdding && this.methods.length === 0);
  }

  get formKind(): ReqpmKindId | null {
    return (this.editing !== "pick" && this.editing?.kind) || null;
  }

  get formMethod(): ReqpmOwnMethod | null {
    return (this.editing !== "pick" && this.editing?.method) || null;
  }

  get kinds(): { id: ReqpmKindId; name: string }[] {
    return KINDS.map((k) => ({
      id: k.id,
      name: i18n(`reqpm.kinds.${k.id}.name`),
    }));
  }

  async load(): Promise<void> {
    try {
      const card = await this.reqpm.card();
      this.methods = card.methods;
      this.max = card.max_methods;
      this.args.onChange?.(card);
      if (this.args.startAdding && this.methods.length === 0) {
        this.editing = "pick";
      }
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  @action
  startAdd() {
    this.editing = "pick";
  }

  @action
  pick(kind: ReqpmKindId) {
    this.editing = { kind };
  }

  @action
  edit(method: ReqpmOwnMethod) {
    this.editing = { method };
  }

  @action
  cancel() {
    this.editing = null;
  }

  @action
  async saved() {
    this.editing = null;
    await this.load();
  }

  @action
  remove(method: ReqpmOwnMethod) {
    this.dialog.deleteConfirm({
      message: i18n("reqpm.editor.delete_confirm", {
        name: this.nameFor(method),
      }),
      didConfirm: async () => {
        try {
          await this.reqpm.deleteMethod(method.id);
          await this.load();
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  @action
  async move(method: ReqpmOwnMethod, delta: number) {
    const ids = this.methods.map((m) => m.id);
    const from = ids.indexOf(method.id);
    const to = from + delta;
    if (to < 0 || to >= ids.length) {
      return;
    }
    ids.splice(to, 0, ids.splice(from, 1)[0]);
    try {
      const card = await this.reqpm.reorder(ids);
      this.methods = card.methods;
      this.args.onChange?.(card);
    } catch (e) {
      popupAjaxError(e);
    }
  }

  <template>
    <div class="reqpm-card-editor">
      <ConditionalLoadingSpinner @condition={{this.loading}}>
        {{#if this.methods.length}}
          <ul class="reqpm-card-editor__list">
            {{#each this.methods as |method index|}}
              <li
                class="reqpm-card-editor__item
                  {{if
                    method.unreadable
                    'reqpm-card-editor__item--unreadable'
                  }}"
              >
                <ReqpmKindIcon @emoji={{method.emoji}} @kind={{method.kind}} />
                <div class="reqpm-card-editor__body">
                  <span class="reqpm-card-editor__name">
                    {{this.nameFor method}}
                    {{#if method.share_by_default}}
                      <span
                        class="reqpm-card-editor__default"
                        title={{i18n "reqpm.editor.default_title"}}
                      >{{i18n "reqpm.editor.default_pill"}}</span>
                    {{/if}}
                  </span>
                  {{#if method.unreadable}}
                    <span class="reqpm-card-editor__value">{{i18n
                        "reqpm.editor.unreadable"
                      }}</span>
                  {{else}}
                    <span
                      class="reqpm-card-editor__value"
                    >{{method.value}}</span>
                  {{/if}}
                  {{#if method.note}}
                    <span class="reqpm-card-editor__note">{{method.note}}</span>
                  {{/if}}
                </div>
                <div class="reqpm-card-editor__actions">
                  <DButton
                    class="btn-flat btn-small"
                    @action={{fn this.move method -1}}
                    @disabled={{eq index 0}}
                    @icon="chevron-up"
                    @title="reqpm.editor.move_up"
                  />
                  <DButton
                    class="btn-flat btn-small"
                    @action={{fn this.move method 1}}
                    @disabled={{isLast index this.methods.length}}
                    @icon="chevron-down"
                    @title="reqpm.editor.move_down"
                  />
                  <DButton
                    class="btn-flat btn-small"
                    @action={{fn this.edit method}}
                    @icon="pencil"
                    @title="reqpm.editor.edit"
                  />
                  <DButton
                    class="btn-flat btn-small btn-danger"
                    @action={{fn this.remove method}}
                    @icon="trash-can"
                    @title="reqpm.editor.delete"
                  />
                </div>
                {{#if (eq this.formMethod method)}}
                  <div class="reqpm-card-editor__inline-form">
                    <ReqpmMethodForm
                      @method={{method}}
                      @onCancel={{this.cancel}}
                      @onSaved={{this.saved}}
                    />
                  </div>
                {{/if}}
              </li>
            {{/each}}
          </ul>
        {{/if}}

        {{#if this.isPicking}}
          <div class="reqpm-card-editor__picker">
            <p class="reqpm-card-editor__picker-title">{{i18n
                "reqpm.editor.pick_title"
              }}</p>
            <div class="reqpm-kind-grid">
              {{#each this.kinds as |kind|}}
                <button
                  class="reqpm-kind-grid__tile"
                  data-kind={{kind.id}}
                  type="button"
                  {{on "click" (fn this.pick kind.id)}}
                >
                  <ReqpmKindIcon @kind={{kind.id}} />
                  <span>{{kind.name}}</span>
                </button>
              {{/each}}
            </div>
            {{#if this.pickerCancellable}}
              <DButton
                class="btn-flat"
                @action={{this.cancel}}
                @label="reqpm.form.cancel"
              />
            {{/if}}
          </div>
        {{else if this.formKind}}
          <div class="reqpm-card-editor__new">
            <ReqpmMethodForm
              @kind={{this.formKind}}
              @onCancel={{this.cancel}}
              @onSaved={{this.saved}}
            />
          </div>
        {{else if this.canAdd}}
          {{#unless this.formMethod}}
            <DButton
              class="btn-default btn-small reqpm-card-editor__add"
              @action={{this.startAdd}}
              @icon="plus"
              @label={{if
                this.methods.length
                "reqpm.editor.add_another"
                "reqpm.editor.add_first"
              }}
            />
          {{/unless}}
        {{else}}
          <p class="reqpm-muted">{{i18n
              "reqpm.editor.limit_reached"
              max=this.max
            }}</p>
        {{/if}}
      </ConditionalLoadingSpinner>
    </div>
  </template>
}
