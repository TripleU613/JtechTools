import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import DButton from "discourse/components/d-button";
import type ToastsService from "discourse/float-kit/services/toasts";
import icon from "discourse/helpers/d-icon";
import { clipboardCopy } from "discourse/lib/utilities";
import { i18n } from "discourse-i18n";
import {
  actionFor,
  isExternal,
  type ReqpmAction,
  type ReqpmActionLabel,
} from "../lib/reqpm-kinds.ts";
import type {
  ReqpmSharedMethod,
  ReqpmSiteSettings,
} from "../services/reqpm.ts";
import ReqpmKindIcon from "./reqpm-kind-icon.gts";

const GO_ICONS: Record<ReqpmActionLabel, string> = {
  call: "phone",
  text: "comment-sms",
  chat: "comment-dots",
  email: "envelope",
  visit: "arrow-up-right-from-square",
  open: "arrow-up-right-from-square",
};

interface ReqpmContactRow {
  method: ReqpmSharedMethod;
  name: string | null;
  go: ReqpmAction | null;
  goLabel: string | null;
  goIcon: string | null;
  external: boolean;
}

interface ReqpmContactListSignature {
  Args: { methods: ReqpmSharedMethod[] | null | undefined };
}

// Someone's shared details, each with a one-tap action (call, text, open
// WhatsApp, …) where one makes sense, and a copy button. Values render as
// plain text; the only links are the fixed-scheme ones from actionFor.
export default class ReqpmContactList extends Component<ReqpmContactListSignature> {
  @service declare toasts: ToastsService;
  @service declare siteSettings: ReqpmSiteSettings;

  @tracked copiedId: number | null = null;

  get rows(): ReqpmContactRow[] {
    return (this.args.methods || []).map((method) => {
      const go = actionFor(
        method,
        this.siteSettings.reqpm_default_country_code
      );
      return {
        method,
        name:
          method.kind === "custom"
            ? method.label
            : i18n(`reqpm.kinds.${method.kind}.name`),
        go,
        goLabel: go ? i18n(`reqpm.actions.${go.label}`) : null,
        goIcon: go ? GO_ICONS[go.label] : null,
        external: go ? isExternal(go.href) : false,
      };
    });
  }

  @action
  copy(method: ReqpmSharedMethod) {
    clipboardCopy(method.value);
    this.copiedId = method.id;
    this.toasts.success({
      duration: "short",
      data: { message: i18n("reqpm.contact_list.copied") },
    });
  }

  <template>
    <ul class="reqpm-contact-list">
      {{#each this.rows as |row|}}
        <li class="reqpm-contact-list__item">
          <ReqpmKindIcon
            @emoji={{row.method.emoji}}
            @kind={{row.method.kind}}
          />
          <div class="reqpm-contact-list__body">
            <span class="reqpm-contact-list__name">{{row.name}}</span>
            <span class="reqpm-contact-list__value">{{row.method.value}}</span>
            {{#if row.method.note}}
              <span class="reqpm-contact-list__note">{{row.method.note}}</span>
            {{/if}}
          </div>
          <div class="reqpm-contact-list__actions">
            {{#if row.go}}
              {{#if row.external}}
                <a
                  class="btn btn-default btn-small reqpm-contact-list__go"
                  href={{row.go.href}}
                  rel="noopener noreferrer nofollow"
                  target="_blank"
                >
                  {{icon row.goIcon}}
                  <span class="d-button-label">{{row.goLabel}}</span>
                </a>
              {{else}}
                <a
                  class="btn btn-default btn-small reqpm-contact-list__go"
                  href={{row.go.href}}
                >
                  {{icon row.goIcon}}
                  <span class="d-button-label">{{row.goLabel}}</span>
                </a>
              {{/if}}
            {{/if}}
            <DButton
              class="btn-default btn-small reqpm-contact-list__copy"
              @action={{fn this.copy row.method}}
              @icon={{if (eq this.copiedId row.method.id) "check" "copy"}}
              @title="reqpm.contact_list.copy"
            />
          </div>
        </li>
      {{/each}}
    </ul>
  </template>
}
