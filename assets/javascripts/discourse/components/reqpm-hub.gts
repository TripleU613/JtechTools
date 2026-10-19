import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import { service } from "@ember/service";
import { modifier } from "ember-modifier";
import { eq } from "truth-helpers";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import DButton from "discourse/components/d-button";
import type DialogService from "discourse/dialog-holder/services/dialog";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import avatar from "discourse/helpers/avatar";
import icon from "discourse/helpers/d-icon";
import { popupAjaxError } from "discourse/lib/ajax-error";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import ReqpmService, {
  ReqpmBasicUser,
  ReqpmCard,
  ReqpmInbox,
  ReqpmIncomingRequest,
  ReqpmOutgoingRequest,
  ReqpmOwnMethod,
  ReqpmReceivedRow,
  ReqpmSentRow,
} from "../services/reqpm.ts";
import ReqpmContactList from "./reqpm-contact-list.gts";
import ReqpmKindIcon from "./reqpm-kind-icon.gts";
import ReqpmPreferences from "./reqpm-preferences.gts";

type ReqpmHubTab = "requests" | "contacts" | "card" | "shared";

const TABS: ReqpmHubTab[] = ["requests", "contacts", "card", "shared"];
const TAB_ICONS: Record<ReqpmHubTab, string> = {
  requests: "hand",
  contacts: "address-card",
  card: "id-card",
  shared: "paper-plane",
};

const isTab = (tab: string | null | undefined): tab is ReqpmHubTab =>
  (TABS as (string | null | undefined)[]).includes(tab);

const profileUrl = (username: string): string => getURL(`/u/${username}`);
const concatState = (state: string): string => `reqpm.hub.state.${state}`;

// Brings the card of the person a notification pointed at into view.
const scrollIntoViewIf = modifier<{
  Element: HTMLElement;
  Args: { Positional: [active: boolean] };
}>((element, [active]) => {
  if (active) {
    element.scrollIntoView({ block: "center", behavior: "smooth" });
  }
});
const kindNames = (kinds: string[] | null | undefined): string =>
  (kinds || []).map((k) => i18n(`reqpm.kinds.${k}.short`)).join(", ");

interface ReqpmHubTabInfo {
  id: ReqpmHubTab;
  icon: string;
  label: string;
  count: number;
  badge: boolean;
}

type ReqpmSentRowWithMethods = ReqpmSentRow & { methods: ReqpmOwnMethod[] };

interface ReqpmHubSignature {
  Args: {
    // The ?tab= and ?user= query params.
    tab?: string | null;
    user?: string | null;
    onTabChange?: (tab: ReqpmHubTab) => void;
  };
}

// /reqpm — everything in one place: requests waiting for you, the details
// people sent you, your own card, and who can see what of it.
export default class ReqpmHub extends Component<ReqpmHubSignature> {
  @service declare reqpm: ReqpmService;
  @service declare dialog: DialogService;

  @tracked inbox: ReqpmInbox | null = null;
  @tracked card: ReqpmCard | null = null;
  @tracked loading = true;
  @tracked filter = "";

  isHighlighted = (username: string): boolean =>
    !!this.args.user &&
    username.toLowerCase() === String(this.args.user).toLowerCase();

  constructor(owner: Owner, args: ReqpmHubSignature["Args"]) {
    super(owner, args);
    this.load();
  }

  get tab(): ReqpmHubTab {
    if (isTab(this.args.tab)) {
      return this.args.tab;
    }
    if (this.inbox?.incoming?.length) {
      return "requests";
    }
    if (this.card && !this.card.methods.length) {
      return "card";
    }
    return "contacts";
  }

  get tabs(): ReqpmHubTabInfo[] {
    return TABS.map((id) => ({
      id,
      icon: TAB_ICONS[id],
      label: i18n(`reqpm.hub.tabs.${id}`),
      count:
        id === "requests"
          ? this.inbox?.incoming?.length || 0
          : id === "contacts"
            ? this.inbox?.received?.length || 0
            : 0,
      badge: id === "requests" && (this.inbox?.incoming?.length || 0) > 0,
    }));
  }

  get received(): ReqpmReceivedRow[] {
    const term = this.filter.trim().toLowerCase();
    const rows = this.inbox?.received || [];
    if (!term) {
      return rows;
    }
    return rows.filter(
      (row) =>
        row.user.username.toLowerCase().includes(term) ||
        (row.user.name || "").toLowerCase().includes(term)
    );
  }

  get sent(): ReqpmSentRowWithMethods[] {
    const byId: Record<number, ReqpmOwnMethod> = Object.fromEntries(
      (this.card?.methods || []).map((m) => [m.id, m])
    );
    return (this.inbox?.sent || []).map((row) => ({
      ...row,
      methods: row.method_ids.map((id) => byId[id]).filter(Boolean),
    }));
  }

  @action
  async load(): Promise<void> {
    try {
      const [inbox, card] = await Promise.all([
        this.reqpm.inbox(),
        this.reqpm.card(),
      ]);
      this.inbox = inbox;
      this.card = card;
      this.reqpm.incomingCount = inbox.incoming.length;
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  @action
  selectTab(id: ReqpmHubTab) {
    this.args.onTabChange?.(id);
  }

  @action
  setFilter(event: Event) {
    this.filter = (event.target as HTMLInputElement).value;
  }

  @action
  async openUser(user: ReqpmBasicUser) {
    await this.reqpm.openUser(user);
    await this.load();
  }

  @action
  async decline(request: ReqpmIncomingRequest) {
    try {
      await this.reqpm.declineRequest(request.id);
      await this.load();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  async withdraw(request: ReqpmOutgoingRequest) {
    try {
      await this.reqpm.cancelRequest(request.id);
      await this.load();
    } catch (e) {
      popupAjaxError(e);
    }
  }

  @action
  forget(row: ReqpmReceivedRow) {
    this.dialog.yesNoConfirm({
      message: i18n("reqpm.user_modal.forget_confirm", {
        username: row.user.username,
      }),
      didConfirm: async () => {
        try {
          await this.reqpm.forget(row.user.username);
          await this.load();
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  @action
  stopSharing(row: ReqpmSentRowWithMethods) {
    this.dialog.yesNoConfirm({
      message: i18n("reqpm.user_modal.stop_confirm", {
        username: row.user.username,
      }),
      didConfirm: async () => {
        try {
          await this.reqpm.revoke(row.user.username);
          await this.load();
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  @action
  cardChanged(card: ReqpmCard) {
    this.card = card;
    if (card.methods.length) {
      this.reqpm.clearSetupPrompt();
    }
  }

  <template>
    <div
      class="reqpm-hub"
      {{didUpdate this.load this.reqpm.refreshToken}}
      {{didUpdate this.load @user}}
    >
      <header class="reqpm-hub__header">
        <h1>{{i18n "reqpm.title"}}</h1>
      </header>

      <nav class="reqpm-tabs" role="tablist">
        {{#each this.tabs as |t|}}
          <button
            aria-selected={{if (eq t.id this.tab) "true" "false"}}
            class="reqpm-tabs__tab {{if (eq t.id this.tab) 'active'}}"
            data-tab={{t.id}}
            role="tab"
            type="button"
            {{on "click" (fn this.selectTab t.id)}}
          >
            {{icon t.icon}}
            <span>{{t.label}}</span>
            {{#if t.count}}
              <span
                class="reqpm-tabs__count
                  {{if t.badge 'reqpm-tabs__count--alert'}}"
              >{{t.count}}</span>
            {{/if}}
          </button>
        {{/each}}
      </nav>

      <ConditionalLoadingSpinner @condition={{this.loading}}>
        {{#if (eq this.tab "requests")}}
          <section class="reqpm-panel">
            <h2>{{i18n "reqpm.hub.incoming_title"}}</h2>
            {{#if this.inbox.incoming.length}}
              <ul class="reqpm-rows">
                {{#each this.inbox.incoming as |req|}}
                  <li class="reqpm-row reqpm-row--incoming">
                    <a href={{profileUrl req.user.username}}>{{avatar
                        req.user
                        imageSize="small"
                      }}</a>
                    <div class="reqpm-row__body">
                      <div><strong>{{req.user.username}}</strong>
                        {{i18n "reqpm.hub.wants_yours"}}</div>
                      {{#if req.wanted_kinds.length}}
                        <div class="reqpm-muted">{{i18n
                            "reqpm.user_modal.they_would_like"
                            kinds=(kindNames req.wanted_kinds)
                          }}</div>
                      {{/if}}
                      <div class="reqpm-muted">{{ageWithTooltip
                          req.created_at
                        }}</div>
                    </div>
                    <div class="reqpm-row__actions">
                      <DButton
                        class="btn-default btn-small reqpm-row__answer"
                        @action={{fn this.openUser req.user}}
                        @label="reqpm.hub.choose_what_to_send"
                      />
                      <DButton
                        class="btn-flat btn-small"
                        @action={{fn this.decline req}}
                        @label="reqpm.user_modal.no_thanks"
                      />
                    </div>
                  </li>
                {{/each}}
              </ul>
            {{else}}
              <p class="reqpm-empty">{{i18n "reqpm.hub.no_incoming"}}</p>
            {{/if}}

            <h2>{{i18n "reqpm.hub.outgoing_title"}}</h2>
            {{#if this.inbox.outgoing.length}}
              <ul class="reqpm-rows">
                {{#each this.inbox.outgoing as |req|}}
                  <li class="reqpm-row">
                    <a href={{profileUrl req.user.username}}>{{avatar
                        req.user
                        imageSize="small"
                      }}</a>
                    <div class="reqpm-row__body">
                      <div><strong>{{req.user.username}}</strong>
                        <span
                          class="reqpm-state reqpm-state--{{req.state}}"
                        >{{i18n (concatState req.state)}}</span></div>
                      <div class="reqpm-muted">{{ageWithTooltip
                          req.created_at
                        }}</div>
                    </div>
                    <div class="reqpm-row__actions">
                      <DButton
                        class="btn-default btn-small"
                        @action={{fn this.openUser req.user}}
                        @label="reqpm.hub.open"
                      />
                      {{#if req.can_cancel}}
                        <DButton
                          class="btn-flat btn-small"
                          @action={{fn this.withdraw req}}
                          @label="reqpm.user_modal.withdraw"
                        />
                      {{/if}}
                    </div>
                  </li>
                {{/each}}
              </ul>
            {{else}}
              <p class="reqpm-empty">{{i18n "reqpm.hub.no_outgoing"}}</p>
            {{/if}}
          </section>
        {{else if (eq this.tab "contacts")}}
          <section class="reqpm-panel">
            {{#if this.inbox.received.length}}
              <input
                class="reqpm-filter"
                placeholder={{i18n "reqpm.hub.filter"}}
                type="search"
                value={{this.filter}}
                {{on "input" this.setFilter}}
              />
              <div class="reqpm-cards">
                {{#each this.received as |row|}}
                  <article
                    class="reqpm-contact-card
                      {{if
                        (this.isHighlighted row.user.username)
                        'reqpm-contact-card--highlight'
                      }}"
                    data-username={{row.user.username}}
                    {{scrollIntoViewIf (this.isHighlighted row.user.username)}}
                  >
                    <header class="reqpm-contact-card__head">
                      <a href={{profileUrl row.user.username}}>{{avatar
                          row.user
                          imageSize="small"
                        }}</a>
                      <div class="reqpm-contact-card__who">
                        <strong>{{row.user.username}}</strong>
                        {{#if row.user.name}}
                          <span class="reqpm-muted">{{row.user.name}}</span>
                        {{/if}}
                      </div>
                      <span class="reqpm-muted reqpm-contact-card__when">{{i18n
                          "reqpm.hub.shared"
                        }}
                        {{ageWithTooltip row.shared_at}}</span>
                    </header>
                    <ReqpmContactList @methods={{row.methods}} />
                    <footer class="reqpm-contact-card__foot">
                      <DButton
                        class="btn-default btn-small"
                        @action={{fn this.openUser row.user}}
                        @label="reqpm.hub.send_yours"
                      />
                      <DButton
                        class="btn-flat btn-small"
                        @action={{fn this.forget row}}
                        @label="reqpm.user_modal.forget"
                      />
                    </footer>
                  </article>
                {{else}}
                  <p class="reqpm-empty">{{i18n "reqpm.hub.no_match"}}</p>
                {{/each}}
              </div>
            {{else}}
              <div class="reqpm-empty reqpm-empty--big">
                {{icon "address-card"}}
                <p>{{i18n "reqpm.hub.no_contacts"}}</p>
                <p class="reqpm-muted">{{i18n "reqpm.hub.how_to_request"}}</p>
              </div>
            {{/if}}
          </section>
        {{else if (eq this.tab "card")}}
          <section class="reqpm-panel">
            <ReqpmPreferences @onChange={{this.cardChanged}} />
          </section>
        {{else if (eq this.tab "shared")}}
          <section class="reqpm-panel">
            {{#if this.sent.length}}
              <ul class="reqpm-rows">
                {{#each this.sent as |row|}}
                  <li class="reqpm-row">
                    <a href={{profileUrl row.user.username}}>{{avatar
                        row.user
                        imageSize="small"
                      }}</a>
                    <div class="reqpm-row__body">
                      <strong>{{row.user.username}}</strong>
                      <div class="reqpm-row__kinds">
                        {{#each row.methods as |m|}}
                          <ReqpmKindIcon @emoji={{m.emoji}} @kind={{m.kind}} />
                        {{/each}}
                        <span class="reqpm-muted">{{ageWithTooltip
                            row.shared_at
                          }}</span>
                      </div>
                    </div>
                    <div class="reqpm-row__actions">
                      <DButton
                        class="btn-default btn-small"
                        @action={{fn this.openUser row.user}}
                        @label="reqpm.hub.change"
                      />
                      <DButton
                        class="btn-flat btn-small btn-danger"
                        @action={{fn this.stopSharing row}}
                        @label="reqpm.user_modal.stop_sharing"
                      />
                    </div>
                  </li>
                {{/each}}
              </ul>
            {{else}}
              <div class="reqpm-empty reqpm-empty--big">
                {{icon "paper-plane"}}
                <p>{{i18n "reqpm.hub.no_shared"}}</p>
              </div>
            {{/if}}
          </section>
        {{/if}}
      </ConditionalLoadingSpinner>
    </div>
  </template>
}
