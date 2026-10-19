import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import type { ComponentLike } from "@glint/template";
import { settings, themePrefix } from "virtual:theme";
import PluginOutlet from "discourse/components/plugin-outlet";
import UntypedTopicExcerpt from "discourse/components/topic-list/topic-excerpt";
import UntypedTopicLink from "discourse/components/topic-list/topic-link";
import UnreadIndicator from "discourse/components/topic-list/unread-indicator";
import TopicPostBadges from "discourse/components/topic-post-badges";
import TopicStatus from "discourse/components/topic-status";
import untypedLazyHash from "discourse/helpers/lazy-hash";
import type Topic from "discourse/models/topic";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import DUserLink from "discourse/ui-kit/d-user-link";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";
import dDiscourseTags from "discourse/ui-kit/helpers/d-discourse-tags";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import dNumber from "discourse/ui-kit/helpers/d-number";
import { i18n } from "discourse-i18n";
import { categoryLinkHTML } from "../lib/jt-core-helpers.ts";
import JtQuickLook from "./jt-quick-look.gts";

// Core declares these two components without a usable signature.
const TopicLink = UntypedTopicLink as unknown as ComponentLike<{
  Element: HTMLAnchorElement;
  Args: { topic: Topic };
}>;
const TopicExcerpt = UntypedTopicExcerpt as unknown as ComponentLike<{
  Element: HTMLAnchorElement;
  Args: { topic: Topic };
}>;
// Declared as taking no arguments; like `hash`, it takes named ones and
// returns them as one object (whose keys stay tracked).
const lazyHash = untypedLazyHash as unknown as <T extends object>(
  named: T
) => T;

// TopicListItemSerializer image sizes (topic.thumbnails)
interface CardThumbnail {
  url: string;
  width: number;
  height: number;
}

// One entry of topic.featuredUsers; the "+N" entry carries moreCount.
interface CardPoster {
  user?: User & { username: string };
  moreCount?: string;
}

type JtCardTopic = Topic & {
  tags?: string[];
  excerpt?: string | null;
  thumbnails?: CardThumbnail[] | null;
  image_url?: string | null;
  like_count: number;
  views: number;
  pinned?: boolean;
  is_hot?: boolean;
  unread_posts?: number;
  unseen?: boolean;
  // discourse-solved
  has_accepted_answer?: boolean;
  accepted_answer?: object | null;
};

export interface JtTopicCardSignature {
  Args: {
    topic: JtCardTopic;
    hideCategory?: boolean;
    bulkSelectEnabled?: boolean;
    isSelected?: boolean;
    onBulkSelectToggle?: (event: Event) => void;
  };
}

// One topic as a card: meta row, title, excerpt, people + stats footer.
// Rendered as the only cell of the row (see api-initializers/jt-topic-cards).
export default class JtTopicCard extends Component<JtTopicCardSignature> {
  @service declare currentUser: User | null;
  @service declare modal: ModalService;

  get topic(): JtCardTopic {
    return this.args.topic;
  }

  get hasSolved() {
    return this.topic.has_accepted_answer || this.topic.accepted_answer;
  }

  get hasTags(): boolean {
    return this.topic.tags?.length > 0;
  }

  // The line over the title (category, tags, pills) is left out when it would
  // be empty: in message lists (core hides the category there) and in a
  // category's own list for a topic without tags or pills. Empty, it still
  // took the card's gap, 8px more above the title than below the footer.
  get hasMeta(): boolean {
    return (
      !this.args.hideCategory ||
      this.hasTags ||
      !!this.hasSolved ||
      !!this.topic.pinned ||
      !!this.topic.is_hot
    );
  }

  get hasExcerpt() {
    return this.topic.excerpt || this.topic.hasExcerpt;
  }

  get posters(): CardPoster[] {
    return (this.topic.featuredUsers || []).filter(
      (p: CardPoster) => !p.moreCount
    );
  }

  get hasReplies(): boolean {
    return this.topic.replyCount > 0;
  }

  get hasLikes(): boolean {
    return this.topic.like_count > 0;
  }

  // The topic's first image: the smallest generated size that is still sharp
  // at 2x (about.json asks core for 320px), else the original. Measured by
  // its longer side, as core fits the image inside 320×320: a tall image's
  // is 160×320, and by its width alone the card loaded the original.
  get thumbnail(): string | null {
    if (!settings.card_thumbnails) {
      return null;
    }
    const side = (t: CardThumbnail) => Math.max(t.width, t.height);
    const sizes = [...(this.topic.thumbnails || [])].sort(
      (a, b) => side(a) - side(b)
    );
    const pick = sizes.find((t) => side(t) >= 240) || sizes.at(-1);
    return pick?.url || this.topic.image_url || null;
  }

  // Signed-in only: the login gate (gated_categories) covers topics for
  // visitors, and Quick look would hand them the whole first post.
  get showQuickLook() {
    return settings.quick_look && this.currentUser;
  }

  @action
  quickLook(event: MouseEvent) {
    // keep the row's click-to-open from firing
    event.preventDefault();
    event.stopPropagation();
    this.modal.show(JtQuickLook, { model: { topic: this.topic } });
  }

  @action
  onTitleFocus(event: FocusEvent) {
    (event.target as HTMLElement)
      .closest(".topic-list-item")
      ?.classList.add("selected");
  }

  @action
  onTitleBlur(event: FocusEvent) {
    (event.target as HTMLElement)
      .closest(".topic-list-item")
      ?.classList.remove("selected");
  }

  <template>
    <td class="jt-card">
      {{#if this.hasMeta}}
        <div class="jt-card__meta">
          {{#unless @hideCategory}}
            <span class="jt-card__category">{{categoryLinkHTML
                @topic.category
              }}</span>
          {{/unless}}
          {{#if this.hasTags}}
            {{dDiscourseTags @topic mode="list" className="jt-card__tags"}}
          {{/if}}
          {{! the words are core's (and the Solved plugin's), so they're translated }}
          <span class="jt-card__flags">
            {{#if this.hasSolved}}
              <span class="jt-pill --solved">
                {{dIcon "check"}}
                {{i18n "solved.title"}}
              </span>
            {{/if}}
            {{#if @topic.pinned}}
              <span class="jt-pill">
                {{dIcon "thumbtack"}}
                {{i18n "topic_statuses.pinned.title"}}
              </span>
            {{/if}}
            {{#if @topic.is_hot}}
              <span class="jt-pill">
                {{dIcon "fire"}}
                {{i18n "topic_statuses.hot.title"}}
              </span>
            {{/if}}
          </span>
        </div>
      {{/if}}

      <div class="jt-card__body">
        <div class="jt-card__text">
          <div aria-level="2" class="jt-card__title" role="heading">
            <TopicStatus @context="topic-list" @topic={{@topic}} />
            <TopicLink
              class="raw-link raw-topic-link"
              @topic={{@topic}}
              {{on "focus" this.onTitleFocus}}
              {{on "blur" this.onTitleBlur}}
            />
            <PluginOutlet
              @name="topic-list-after-title"
              @outletArgs={{lazyHash topic=@topic}}
            />
            <UnreadIndicator @topic={{@topic}} />
            <TopicPostBadges
              @unreadPosts={{@topic.unread_posts}}
              @unseen={{@topic.unseen}}
              @url={{@topic.lastUnreadUrl}}
            />
          </div>

          {{#if this.hasExcerpt}}
            <TopicExcerpt class="jt-card__excerpt" @topic={{@topic}} />
          {{/if}}
        </div>

        {{#if this.thumbnail}}
          <img
            alt=""
            class="jt-card__thumb"
            decoding="async"
            loading="lazy"
            src={{this.thumbnail}}
          />
        {{/if}}
      </div>

      <div class="jt-card__foot">
        {{! as core's posters column: each face opens that person's card }}
        <span class="jt-card__people">
          {{#each this.posters as |poster|}}
            <DUserLink
              @href={{poster.user.path}}
              @username={{poster.user.username}}
            >
              {{dAvatar
                poster
                avatarTemplatePath="user.avatar_template"
                usernamePath="user.username"
                namePath="user.name"
                imageSize="small"
              }}
            </DUserLink>
          {{/each}}
        </span>

        <span class="jt-card__stats">
          {{#if this.hasReplies}}
            <span
              class="jt-card__stat"
              title={{i18n (themePrefix "jt.replies") count=@topic.replyCount}}
            >
              {{dIcon "far-comment"}}
              {{dNumber @topic.replyCount}}
            </span>
          {{/if}}
          <span
            class="jt-card__stat"
            title={{i18n (themePrefix "jt.views") count=@topic.views}}
          >
            {{dIcon "far-eye"}}
            {{dNumber @topic.views}}
          </span>
          {{#if this.hasLikes}}
            <span
              class="jt-card__stat"
              title={{i18n (themePrefix "jt.likes") count=@topic.like_count}}
            >
              {{dIcon "far-heart"}}
              {{dNumber @topic.like_count}}
            </span>
          {{/if}}
          {{#if this.showQuickLook}}
            <button
              aria-label={{i18n (themePrefix "jt.quick_look")}}
              class="btn btn-flat no-text jt-card__peek"
              title={{i18n (themePrefix "jt.quick_look")}}
              type="button"
              {{on "click" this.quickLook}}
            >{{dIcon "expand"}}</button>
          {{/if}}
          <span class="jt-card__stat --activity">
            {{dFormatDate @topic.bumpedAt format="tiny"}}
          </span>
        </span>
      </div>
    </td>
  </template>
}
