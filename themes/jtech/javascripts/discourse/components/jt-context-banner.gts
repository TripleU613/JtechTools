import Component from "@glimmer/component";
import { settings, themePrefix } from "virtual:theme";
import type Category from "discourse/models/category";
import type Tag from "discourse/models/tag";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import dNumber from "discourse/ui-kit/helpers/d-number";
import { i18n } from "discourse-i18n";
import { dEmoji } from "../lib/jt-core-helpers.ts";

type BannerCategory = Category & {
  uploaded_logo?: { url: string } | null;
  subcategory_count?: number | null;
};

type BannerTag = Tag & {
  name: string;
  description?: string | null;
  topic_count?: number;
};

export interface JtContextBannerSignature {
  Args: {
    category?: BannerCategory | null;
    tag?: BannerTag | null;
  };
}

// Header for category and tag pages: tile, breadcrumb, name, description,
// counts. Reads only fields the category/tag models already carry.
export default class JtContextBanner extends Component<JtContextBannerSignature> {
  get category(): BannerCategory | null | undefined {
    return settings.category_banners ? this.args.category : null;
  }

  get tag(): BannerTag | null | undefined {
    return !this.args.category && settings.tag_banners ? this.args.tag : null;
  }

  get logoUrl(): string | undefined {
    return this.category?.uploaded_logo?.url;
  }

  get initials(): string {
    const words = (this.category?.displayName || "")
      .split(/\s+/)
      .filter(Boolean);
    const s =
      words.length > 1
        ? words[0][0] + words[1][0]
        : (words[0] || "").slice(0, 2);
    return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase();
  }

  get subcategoryCount(): number {
    // subcategory_count includes children not loaded yet (lazy categories)
    return (
      this.category?.subcategory_count ??
      this.category?.subcategories?.length ??
      0
    );
  }

  <template>
    {{#if this.category}}
      <section
        aria-labelledby="jt-banner-title"
        class="jt-banner {{if this.logoUrl '--has-logo'}}"
      >
        <span aria-hidden="true" class="jt-banner__tile">
          {{#if this.logoUrl}}
            <img alt="" src={{this.logoUrl}} />
          {{else if this.category.icon}}
            {{dIcon this.category.icon}}
          {{else if this.category.emoji}}
            {{dEmoji this.category.emoji}}
          {{else}}
            {{this.initials}}
          {{/if}}
        </span>
        <div class="jt-banner__body">
          {{#if this.category.parentCategory}}
            <a
              class="jt-banner__parent"
              href={{this.category.parentCategory.url}}
            >{{this.category.parentCategory.displayName}}</a>
          {{/if}}
          <h2 class="jt-banner__title" id="jt-banner-title">
            {{this.category.displayName}}
          </h2>
          {{#if this.category.descriptionText}}
            <p class="jt-banner__desc">{{this.category.descriptionText}}</p>
          {{/if}}
          <div class="jt-banner__stats">
            <span>{{dNumber this.category.totalTopicCount}}
              {{i18n
                (themePrefix "jt.topics_label")
                count=this.category.totalTopicCount
              }}</span>
            {{#if this.subcategoryCount}}
              <span>{{this.subcategoryCount}}
                {{i18n
                  (themePrefix "jt.subcategories_label")
                  count=this.subcategoryCount
                }}</span>
            {{/if}}
          </div>
        </div>
      </section>
    {{else if this.tag}}
      <section aria-labelledby="jt-banner-title" class="jt-banner --tag">
        <span aria-hidden="true" class="jt-banner__tile">#</span>
        <div class="jt-banner__body">
          <span class="jt-banner__parent">{{i18n (themePrefix "jt.tag")}}</span>
          <h2 class="jt-banner__title" id="jt-banner-title">
            {{this.tag.name}}
          </h2>
          {{#if this.tag.description}}
            <p class="jt-banner__desc">{{this.tag.description}}</p>
          {{/if}}
          {{#if this.tag.topic_count}}
            <div class="jt-banner__stats">
              <span>{{dNumber this.tag.topic_count}}
                {{i18n
                  (themePrefix "jt.topics_label")
                  count=this.tag.topic_count
                }}</span>
            </div>
          {{/if}}
        </div>
      </section>
    {{/if}}
  </template>
}
