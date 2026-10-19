import Component from "@glimmer/component";
import { service } from "@ember/service";
import { settings, themePrefix } from "virtual:theme";
import bodyClass from "discourse/helpers/body-class";
import routeAction from "discourse/helpers/route-action";
import getURL from "discourse/lib/get-url";
import type Topic from "discourse/models/topic";
import type User from "discourse/models/user";
import type SiteSettings from "discourse/services/site-settings";
import DButton from "discourse/ui-kit/d-button";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { categoryLinkHTML } from "../lib/jt-core-helpers.ts";
import JtechMark from "./jtech-mark.gts";

export type GateTopic = Topic & {
  category_id: number;
  tags?: (string | { name: string })[];
};

interface GateSiteSettings {
  allow_new_registrations: boolean;
  invite_only: boolean;
}

interface JtGateSignature {
  Args: { topic?: GateTopic | null };
}

function listSetting(value: string): string[] {
  return (value || "").split("|").filter(Boolean);
}

// Logged-out visitors on a topic in a gated category, or with a gated tag, see
// its first lines fade into a prompt to log in or sign up (jt-gate.scss). It
// only hides the topic in the browser: the post is still sent to them.
export default class JtGate extends Component<JtGateSignature> {
  @service declare currentUser: User | null;
  @service declare siteSettings: SiteSettings & GateSiteSettings;

  get topic(): GateTopic | null | undefined {
    return this.args.topic;
  }

  get gated(): boolean {
    if (this.currentUser || !this.topic || this.topic.isPrivateMessage) {
      return false;
    }
    const categories = listSetting(settings.gated_categories).map(Number);
    if (categories.includes(this.topic.category_id)) {
      return true;
    }
    const tags = listSetting(settings.gated_tags);
    return (this.topic.tags || []).some((tag) =>
      tags.includes(typeof tag === "string" ? tag : tag?.name)
    );
  }

  get canSignUp(): boolean {
    return (
      this.siteSettings.allow_new_registrations &&
      !this.siteSettings.invite_only
    );
  }

  get categoriesURL(): string {
    return getURL("/categories");
  }

  get description(): string {
    const category = this.topic.category;
    return category
      ? i18n(themePrefix("jt.gate.description"), { category: category.name })
      : i18n(themePrefix("jt.gate.description_no_category"));
  }

  <template>
    {{#if this.gated}}
      {{bodyClass "jt-gated"}}
      <section aria-labelledby="jt-gate-title" class="jt-gate">
        <div class="jt-gate__card">
          <div aria-hidden="true" class="jt-gate__badge">
            <JtechMark />
            <span class="jt-gate__lock">{{dIcon "lock"}}</span>
          </div>

          {{#if this.topic.category}}
            <div class="jt-gate__category">
              {{categoryLinkHTML this.topic.category}}
            </div>
          {{/if}}

          <h2 class="jt-gate__title" id="jt-gate-title">
            {{i18n (themePrefix "jt.gate.title")}}
          </h2>
          {{! English around the category's name: read in its own direction,
            or a Hebrew interface scrambles the sentence }}
          <p class="jt-gate__text" dir="auto">{{this.description}}</p>

          <div class="jt-gate__actions">
            {{#if this.canSignUp}}
              <DButton
                class="btn-primary jt-gate__sign-up"
                @action={{routeAction "showCreateAccount"}}
                @translatedLabel={{i18n (themePrefix "jt.gate.sign_up")}}
              />
            {{/if}}
            <DButton
              class={{if
                this.canSignUp
                "btn-default jt-gate__log-in"
                "btn-primary jt-gate__log-in"
              }}
              @action={{routeAction "showLogin"}}
              @translatedLabel={{i18n (themePrefix "jt.gate.log_in")}}
            />
          </div>

          <a class="jt-gate__browse" href={{this.categoriesURL}}>
            {{i18n (themePrefix "jt.gate.browse")}}
            {{dIcon "arrow-right"}}
          </a>
        </div>
      </section>
    {{/if}}
  </template>
}
