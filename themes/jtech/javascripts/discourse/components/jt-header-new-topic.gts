import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import type Category from "discourse/models/category";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type ComposerService from "discourse/services/composer";
import type DiscoveryService from "discourse/services/discovery";
import type SiteSettingsService from "discourse/services/site-settings";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { jtLabel } from "../lib/jt-labels.ts";

type NewTopicUser = User & { can_create_topic?: boolean };

type NewTopicCategory = Category & {
  canCreateTopic?: boolean;
  subcategoryWithCreateTopicPermission?: Category;
};

interface NewTopicSiteSettings {
  default_subcategory_on_read_only_category: boolean;
}

interface JtHeaderNewTopicSignature {
  Args: Record<string, never>;
}

// "+" in the header: start a topic from anywhere, in the category and tag
// you're looking at when there is one. Picks the category the way core's own
// New Topic button does (controllers/discovery/list.js).
export default class JtHeaderNewTopic extends Component<JtHeaderNewTopicSignature> {
  @service declare composer: ComposerService;
  @service declare currentUser: NewTopicUser | null;
  @service declare discovery: DiscoveryService;
  @service declare site: Site;
  @service declare siteSettings: SiteSettingsService & NewTopicSiteSettings;

  get show(): boolean {
    return this.currentUser?.can_create_topic && !this.site.isReadOnly;
  }

  get category(): Category | undefined {
    const category: NewTopicCategory | undefined = this.discovery?.category;
    if (!category || category.canCreateTopic) {
      return category;
    }
    if (this.siteSettings.default_subcategory_on_read_only_category) {
      return category.subcategoryWithCreateTopicPermission ?? category;
    }
    return category;
  }

  get tags(): string | undefined {
    const name: string | undefined = this.discovery?.tag?.name;
    return name && !["none", "all"].includes(name) ? name : undefined;
  }

  @action
  newTopic() {
    this.composer.openNewTopic({ category: this.category, tags: this.tags });
  }

  <template>
    {{#if this.show}}
      <li class="header-dropdown-toggle jt-header-new-topic">
        <button
          aria-label={{jtLabel "cmdk.new_topic"}}
          class="btn btn-flat no-text icon jt-header-icon"
          title={{jtLabel "cmdk.new_topic"}}
          type="button"
          {{on "click" this.newTopic}}
        >{{dIcon "plus"}}</button>
      </li>
    {{/if}}
  </template>
}
