import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import DButton from "discourse/components/d-button";
import DModal from "discourse/components/d-modal";
import type DialogService from "discourse/dialog-holder/services/dialog";
import avatar from "discourse/helpers/avatar";
import icon from "discourse/helpers/d-icon";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { shortDate } from "discourse/lib/formatter";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import { KINDS, type ReqpmKindId } from "../lib/reqpm-kinds.ts";
import ReqpmService, {
  ReqpmBlockedReason,
  ReqpmCard,
  ReqpmCurrentUser,
  reqpmError,
  ReqpmOwnMethod,
  ReqpmRelationship,
  ReqpmSharedMethod,
  ReqpmUserRef,
} from "../services/reqpm.ts";
import ReqpmCardEditor from "./reqpm-card-editor.gts";
import ReqpmContactList from "./reqpm-contact-list.gts";
import ReqpmKindIcon from "./reqpm-kind-icon.gts";

const isEmpty = (list: unknown[] | null | undefined): boolean =>
  !list || list.length === 0;
const joinList = (list: string[]): string => list.join(", ");

function dateLabel(value: string | null | undefined): string {
  return value ? shortDate(value) : "";
}

interface ReqpmUserModalSignature {
  Args: {
    model: { user: ReqpmUserRef };
    closeModal: () => void;
  };
}

interface ReqpmWantedChoice {
  id: ReqpmKindId;
  name: string;
  on: boolean;
}

interface ReqpmShareChoice {
  method: ReqpmOwnMethod;
  name: string | null;
  checked: boolean;
}

// The REQ-PM window for one other member, opened from their user card or
// profile, or from a notification. Everything between the two of you in one
// place: what they sent you, asking for their details, and choosing which of
// your own details they may see.
export default class ReqpmUserModal extends Component<ReqpmUserModalSignature> {
  @service declare reqpm: ReqpmService;
  @service declare dialog: DialogService;
  @service declare router: RouterService;
  @service declare currentUser: ReqpmCurrentUser;

  @tracked data: ReqpmRelationship | null = null;
  @tracked loading = true;
  @tracked busy = false;
  @tracked selected: number[] = [];
  @tracked wanted: ReqpmKindId[] = [];
  @tracked notice: string | null = null;
  @tracked requestError: string | null = null;
  @tracked shareError: string | null = null;

  constructor(owner: Owner, args: ReqpmUserModalSignature["Args"]) {
    super(owner, args);
    this.load();
  }

  get username(): string {
    return this.args.model.user.username;
  }

  get title(): string {
    return i18n("reqpm.user_modal.title", { username: this.username });
  }

  get user(): ReqpmUserRef {
    return this.data?.user || this.args.model.user;
  }

  get theirMethods(): ReqpmSharedMethod[] {
    return this.data?.their_methods || [];
  }

  get myMethods(): ReqpmOwnMethod[] {
    return (this.data?.my_methods || []).filter((m) => !m.unreadable);
  }

  get alreadyShared(): boolean {
    return (this.data?.my_shared_method_ids || []).length > 0;
  }

  get outgoing(): ReqpmRelationship["outgoing_request"] | undefined {
    return this.data?.outgoing_request;
  }

  get requestState(): "can" | ReqpmBlockedReason | null {
    const d = this.data;
    if (!d) {
      return null;
    }
    if (d.can_request) {
      return "can";
    }
    return d.request_blocked;
  }

  get wantedChoices(): ReqpmWantedChoice[] {
    return KINDS.map((k) => ({
      id: k.id,
      name: i18n(`reqpm.kinds.${k.id}.short`),
      on: this.wanted.includes(k.id),
    }));
  }

  get incomingWanted(): string[] {
    return (this.data?.incoming_request?.wanted_kinds || []).map((k) =>
      i18n(`reqpm.kinds.${k}.short`)
    );
  }

  get shareChoices(): ReqpmShareChoice[] {
    return this.myMethods.map((m) => ({
      method: m,
      name: m.kind === "custom" ? m.label : i18n(`reqpm.kinds.${m.kind}.name`),
      checked: this.selected.includes(m.id),
    }));
  }

  get shareLabel(): string {
    return this.alreadyShared
      ? "reqpm.user_modal.update_share"
      : "reqpm.user_modal.send";
  }

  get pendingSince(): string {
    return dateLabel(this.outgoing?.created_at);
  }

  get retryDate(): string {
    return dateLabel(this.data?.retry_at);
  }

  get profileUrl(): string {
    return getURL(`/u/${this.username}`);
  }

  async load(): Promise<void> {
    try {
      this.apply(await this.reqpm.relationship(this.username));
    } catch (e) {
      popupAjaxError(e);
      this.args.closeModal();
    } finally {
      this.loading = false;
    }
  }

  apply(data: ReqpmRelationship): void {
    this.data = data;
    this.selected = this.initialSelection(data);
  }

  // Already shared → exactly that. Answering a request → what they asked
  // for, when you have it. Otherwise → your "send by default" ones.
  initialSelection(data: ReqpmRelationship): number[] {
    const mine = data.my_methods.filter((m) => !m.unreadable);
    if (data.my_shared_method_ids.length) {
      return [...data.my_shared_method_ids];
    }
    const wanted = data.incoming_request?.wanted_kinds || [];
    if (wanted.length) {
      const matching = mine.filter((m) => wanted.includes(m.kind));
      if (matching.length) {
        return matching.map((m) => m.id);
      }
    }
    return mine.filter((m) => m.share_by_default).map((m) => m.id);
  }

  @action
  toggleWanted(kind: ReqpmKindId) {
    this.wanted = this.wanted.includes(kind)
      ? this.wanted.filter((k) => k !== kind)
      : [...this.wanted, kind];
  }

  @action
  toggleSelected(id: number, event: Event) {
    this.selected = (event.target as HTMLInputElement).checked
      ? [...new Set([...this.selected, id])]
      : this.selected.filter((x) => x !== id);
  }

  @action
  async sendRequest() {
    this.busy = true;
    this.requestError = null;
    try {
      this.apply(await this.reqpm.request(this.username, this.wanted));
      this.notice = i18n("reqpm.user_modal.request_sent", {
        username: this.username,
      });
    } catch (e) {
      this.requestError = reqpmError(e).message || i18n("reqpm.errors.generic");
    } finally {
      this.busy = false;
    }
  }

  @action
  async withdraw() {
    this.busy = true;
    try {
      await this.reqpm.cancelRequest(this.outgoing.id);
      this.notice = null;
      this.apply(await this.reqpm.relationship(this.username));
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  }

  @action
  async decline() {
    this.busy = true;
    try {
      await this.reqpm.declineRequest(this.data.incoming_request.id);
      this.apply(await this.reqpm.relationship(this.username));
      this.notice = i18n("reqpm.user_modal.declined");
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  }

  @action
  async share() {
    if (!this.selected.length) {
      return;
    }
    this.busy = true;
    this.shareError = null;
    try {
      this.apply(await this.reqpm.share(this.username, this.selected));
      this.notice = i18n("reqpm.user_modal.shared", {
        username: this.username,
      });
    } catch (e) {
      this.shareError = reqpmError(e).message || i18n("reqpm.errors.generic");
    } finally {
      this.busy = false;
    }
  }

  @action
  stopSharing() {
    this.dialog.yesNoConfirm({
      message: i18n("reqpm.user_modal.stop_confirm", {
        username: this.username,
      }),
      didConfirm: async () => {
        try {
          this.apply(await this.reqpm.revoke(this.username));
          this.notice = i18n("reqpm.user_modal.stopped", {
            username: this.username,
          });
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  @action
  forget() {
    this.dialog.yesNoConfirm({
      message: i18n("reqpm.user_modal.forget_confirm", {
        username: this.username,
      }),
      didConfirm: async () => {
        try {
          await this.reqpm.forget(this.username);
          this.apply(await this.reqpm.relationship(this.username));
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  @action
  async cardChanged(card: ReqpmCard | null | undefined) {
    // First method added from inside this window: reload so the picker
    // appears with it pre-ticked.
    if (!card?.methods?.length) {
      return;
    }
    this.reqpm.clearSetupPrompt();
    this.apply(await this.reqpm.relationship(this.username));
  }

  @action
  openHub() {
    this.args.closeModal();
    this.router.transitionTo("preferences.reqpm", this.currentUser.username);
  }

  <template>
    <DModal
      class="reqpm-user-modal"
      @closeModal={{@closeModal}}
      @title={{this.title}}
    >
      <:body>
        <ConditionalLoadingSpinner @condition={{this.loading}}>
          {{#if this.data}}
            <div class="reqpm-user-modal__who">
              <a href={{this.profileUrl}}>{{avatar
                  this.user
                  imageSize="medium"
                }}</a>
              <div>
                <div
                  class="reqpm-user-modal__username"
                >{{this.user.username}}</div>
                {{#if this.user.name}}
                  <div class="reqpm-muted">{{this.user.name}}</div>
                {{/if}}
              </div>
            </div>

            {{#if this.notice}}
              <div class="reqpm-callout reqpm-callout--success" role="status">
                {{icon "check"}}
                <span>{{this.notice}}</span>
              </div>
            {{/if}}

            {{#if this.data.incoming_request}}
              <div class="reqpm-callout reqpm-callout--incoming">
                {{icon "hand"}}
                <div>
                  <strong>{{i18n
                      "reqpm.user_modal.they_asked"
                      username=this.username
                    }}</strong>
                  {{#if this.incomingWanted.length}}
                    <div class="reqpm-muted">{{i18n
                        "reqpm.user_modal.they_would_like"
                        kinds=(joinList this.incomingWanted)
                      }}</div>
                  {{/if}}
                  <DButton
                    class="btn-flat btn-small reqpm-user-modal__decline"
                    @action={{this.decline}}
                    @disabled={{this.busy}}
                    @label="reqpm.user_modal.no_thanks"
                  />
                </div>
              </div>
            {{/if}}

            <div
              class="reqpm-user-modal__sections
                {{if
                  this.data.incoming_request
                  'reqpm-user-modal__sections--answering'
                }}"
            >
              <section class="reqpm-section reqpm-section--theirs">
                <h3>{{i18n
                    "reqpm.user_modal.their_details"
                    username=this.username
                  }}</h3>
                {{#if this.theirMethods.length}}
                  <ReqpmContactList @methods={{this.theirMethods}} />
                  <DButton
                    class="btn-flat btn-small reqpm-user-modal__forget"
                    @action={{this.forget}}
                    @label="reqpm.user_modal.forget"
                  />
                {{else}}
                  <p class="reqpm-muted">{{i18n
                      "reqpm.user_modal.nothing_yet"
                      username=this.username
                    }}</p>
                {{/if}}

                {{#if (eq this.requestState "can")}}
                  <div class="reqpm-ask">
                    <p class="reqpm-ask__label">{{i18n
                        "reqpm.user_modal.what_would_you_like"
                      }}</p>
                    <div class="reqpm-chips">
                      {{#each this.wantedChoices as |choice|}}
                        <button
                          aria-pressed={{if choice.on "true" "false"}}
                          class="reqpm-chip {{if choice.on 'reqpm-chip--on'}}"
                          type="button"
                          {{on "click" (fn this.toggleWanted choice.id)}}
                        >
                          <ReqpmKindIcon @kind={{choice.id}} />
                          {{choice.name}}
                        </button>
                      {{/each}}
                    </div>
                    {{#if this.requestError}}
                      <div
                        class="reqpm-error"
                        role="alert"
                      >{{this.requestError}}</div>
                    {{/if}}
                    <DButton
                      class="btn-default btn-small reqpm-user-modal__request"
                      @action={{this.sendRequest}}
                      @isLoading={{this.busy}}
                      @label="reqpm.user_modal.request"
                    />
                  </div>
                {{else if (eq this.requestState "pending")}}
                  <div class="reqpm-status">
                    {{icon "clock"}}
                    <span>{{i18n
                        "reqpm.user_modal.pending"
                        date=this.pendingSince
                        username=this.username
                      }}</span>
                    {{#if this.outgoing.can_cancel}}
                      <DButton
                        class="btn-flat btn-small"
                        @action={{this.withdraw}}
                        @disabled={{this.busy}}
                        @label="reqpm.user_modal.withdraw"
                      />
                    {{/if}}
                  </div>
                {{else if (eq this.requestState "cooldown")}}
                  <div class="reqpm-status">
                    {{icon "clock"}}
                    <span>{{i18n
                        "reqpm.user_modal.cooldown"
                        date=this.retryDate
                      }}</span>
                  </div>
                {{else if (eq this.requestState "unavailable")}}
                  {{#unless this.theirMethods.length}}
                    <div class="reqpm-status">
                      {{icon "user-lock"}}
                      <span>{{i18n
                          "reqpm.user_modal.unavailable"
                          username=this.username
                        }}</span>
                    </div>
                  {{/unless}}
                {{/if}}
              </section>

              <section class="reqpm-section reqpm-section--send">
                <h3>{{i18n "reqpm.user_modal.your_details"}}</h3>
                {{#if this.data.can_share}}
                  {{#if this.myMethods.length}}
                    <ul class="reqpm-share-list">
                      {{#each this.shareChoices as |choice|}}
                        <li>
                          <label class="reqpm-share-list__item">
                            <input
                              checked={{choice.checked}}
                              type="checkbox"
                              {{on
                                "change"
                                (fn this.toggleSelected choice.method.id)
                              }}
                            />
                            <ReqpmKindIcon
                              @emoji={{choice.method.emoji}}
                              @kind={{choice.method.kind}}
                            />
                            <span class="reqpm-share-list__text">
                              <span
                                class="reqpm-share-list__name"
                              >{{choice.name}}</span>
                              <span
                                class="reqpm-share-list__value"
                              >{{choice.method.value}}</span>
                            </span>
                          </label>
                        </li>
                      {{/each}}
                    </ul>
                    {{#if this.shareError}}
                      <div
                        class="reqpm-error"
                        role="alert"
                      >{{this.shareError}}</div>
                    {{/if}}
                    <div class="reqpm-user-modal__send-buttons">
                      <DButton
                        class="btn-primary btn-small reqpm-user-modal__send"
                        @action={{this.share}}
                        @disabled={{isEmpty this.selected}}
                        @icon="paper-plane"
                        @isLoading={{this.busy}}
                        @label={{this.shareLabel}}
                      />
                      {{#if this.alreadyShared}}
                        <DButton
                          class="btn-flat btn-danger"
                          @action={{this.stopSharing}}
                          @label="reqpm.user_modal.stop_sharing"
                        />
                      {{/if}}
                    </div>
                    <DButton
                      class="btn-flat btn-small reqpm-user-modal__edit-card"
                      @action={{this.openHub}}
                      @icon="pencil"
                      @label="reqpm.user_modal.edit_card"
                    />
                  {{else}}
                    <ReqpmCardEditor
                      @onChange={{this.cardChanged}}
                      @startAdding={{true}}
                    />
                  {{/if}}
                {{else}}
                  <div class="reqpm-status">
                    {{icon "user-lock"}}
                    <span>{{i18n
                        "reqpm.user_modal.cannot_share"
                        username=this.username
                      }}</span>
                  </div>
                {{/if}}
              </section>
            </div>
          {{/if}}
        </ConditionalLoadingSpinner>
      </:body>
      <:footer>
        <DButton
          class="btn-default"
          @action={{@closeModal}}
          @label="reqpm.user_modal.close"
        />
      </:footer>
    </DModal>
  </template>
}
