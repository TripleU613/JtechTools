import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import { service } from "@ember/service";
import { type TrustedHTML, trustHTML } from "@ember/template";
import icon from "discourse/helpers/d-icon";
import { cook } from "discourse/lib/text";
import { setTextDirections } from "discourse/lib/text-direction";
import type AppEventsService from "discourse/services/app-events";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import {
  type FooterMessageSiteSettings,
  type FooterMessageTopic,
  topicFooterFeatureActive,
  topicFooterMessage,
} from "../../lib/topic-footer-message.ts";

type DirectionSiteSettings = SiteSettings & {
  support_mixed_text_direction: boolean;
};

// DiscourseModCategories.serialized_pinned_post, or a post-stream post.
interface PinnedPost {
  id: number;
  post_number: number;
  cooked: string;
  username: string;
  name?: string | null;
  avatar_template?: string | null;
}

interface FooterTopic extends FooterMessageTopic {
  id: number;
  url: string;
  highest_post_number?: number;
  mod_topic_pinned_post_id?: number | null;
  mod_topic_pinned_post?: PinnedPost | null;
  postStream?: { posts?: PinnedPost[] };
}

interface TopicFooterMessageSignature {
  Args: { outletArgs: { model: FooterTopic } };
}

// Renders the moderator-curated content at the end of the post stream,
// above the reply button:
//   - a post a moderator pinned to the bottom, shown as a regular-looking
//     post (avatar, username, content) with a pin badge and a button
//     linking up to the original post, and/or
//   - the moderator-set `mod_topic_footer_message`.
//
// `shouldRender` is static and only gates on things that cannot change
// while the page is open. The visible content is held in tracked state
// and refreshed on the `discourse-mod:messages-updated` appEvent fired by
// the moderator edit UIs, so changes appear immediately without a reload.
//
// Discourse reuses this connector instance across topic navigation, so the
// tracked state is also re-read whenever the topic id changes (via a
// `{{did-update}}` modifier) — otherwise the previous topic's footer would
// stay stuck on the new topic.
export default class TopicFooterMessage extends Component<TopicFooterMessageSignature> {
  static shouldRender(
    args: TopicFooterMessageSignature["Args"]["outletArgs"] | undefined,
    context: { siteSettings?: FooterMessageSiteSettings } | undefined,
    owner: Owner | undefined
  ): boolean {
    const siteSettings =
      (owner?.lookup("service:site-settings") as
        | FooterMessageSiteSettings
        | undefined) || context?.siteSettings;
    return topicFooterFeatureActive(siteSettings, args?.model);
  }

  @service declare appEvents: AppEventsService;
  @service declare siteSettings: DirectionSiteSettings;

  @tracked footerMessage = topicFooterMessage(this.topic);
  @tracked pinnedPostId = this.topic?.mod_topic_pinned_post_id || null;
  @tracked pinnedPostPayload = this.topic?.mod_topic_pinned_post || null;
  @tracked cookedFooterMessage: TrustedHTML | null = null;

  constructor(owner: Owner, args: TopicFooterMessageSignature["Args"]) {
    super(owner, args);
    this.appEvents.on(
      "discourse-mod:messages-updated",
      this,
      this.refreshFromTopic
    );
    this.cookFooterMessage();
  }

  willDestroy() {
    super.willDestroy();
    this.appEvents.off(
      "discourse-mod:messages-updated",
      this,
      this.refreshFromTopic
    );
  }

  get topic(): FooterTopic {
    return this.args.outletArgs.model;
  }

  get messageHtml(): TrustedHTML | null {
    return this.cookedFooterMessage;
  }

  // Prefer the topic-attached payload (serialized server-side and returned
  // by the pin endpoint) so the bottom copy renders immediately, even when
  // the pinned post lives outside the currently-loaded post-stream window.
  // The `postStream.posts` lookup is the historical fallback — kept so a
  // stale topic-view that predates the new field still renders.
  get pinnedPost(): PinnedPost | null {
    if (!this.pinnedPostId) {
      return null;
    }
    if (this.pinnedPostPayload?.id === this.pinnedPostId) {
      return this.pinnedPostPayload;
    }
    return (
      this.topic?.postStream?.posts?.find((p) => p.id === this.pinnedPostId) ||
      null
    );
  }

  // The bottom copy is skipped when the pinned post is already the last
  // post of the topic — the in-stream pin badge is enough in that case.
  get showPinnedCopy(): boolean {
    const post = this.pinnedPost;
    if (!post) {
      return false;
    }
    const highest = this.topic?.highest_post_number;
    return !highest || post.post_number !== highest;
  }

  get pinnedPostHtml(): TrustedHTML | null {
    return this.pinnedPost ? trustHTML(this.pinnedPost.cooked) : null;
  }

  get pinnedAvatarUrl(): string | null {
    const template = this.pinnedPost?.avatar_template;
    return template ? template.replace("{size}", "45") : null;
  }

  get originalPostUrl(): string | null {
    const topic = this.topic;
    const post = this.pinnedPost;
    if (!topic || !post) {
      return null;
    }
    return `${topic.url}/${post.post_number}`;
  }

  // appEvent handler for live edits within the current topic. The guard
  // keeps a stale event for another topic from clobbering this one.
  refreshFromTopic(topic: FooterTopic | null | undefined): void {
    if (!topic || topic.id !== this.topic?.id) {
      return;
    }
    this.readTopicState(topic);
  }

  // With core's "support mixed text direction" on, each paragraph of a post
  // reads in its own direction: core marks them as it renders the post
  // stream. The pinned post's copy down here and the moderator's message are
  // rendered outside the stream, so they kept the interface's direction: in
  // Hebrew an English post's full stops came first, its bullets sat on the
  // right and a poll read "voters 0". They're marked the same way.
  @action
  markDirections(element: HTMLElement) {
    if (this.siteSettings.support_mixed_text_direction) {
      setTextDirections(element);
    }
  }

  // Re-read all per-topic state from the current topic. Called on initial
  // insert and whenever the connector is reused for a different topic.
  @action
  refreshOnNavigation() {
    this.readTopicState(this.topic);
  }

  readTopicState(topic: FooterTopic | null | undefined): void {
    this.footerMessage = topicFooterMessage(topic);
    this.pinnedPostId = topic?.mod_topic_pinned_post_id || null;
    this.pinnedPostPayload = topic?.mod_topic_pinned_post || null;
    this.cookFooterMessage();
  }

  // Cooks the raw moderator markdown into HTML asynchronously and stores
  // the result in tracked state. The stored/edited value stays raw — only
  // the display is cooked.
  async cookFooterMessage(): Promise<void> {
    const raw = this.footerMessage;
    if (!raw) {
      this.cookedFooterMessage = null;
      return;
    }
    const cooked: TrustedHTML = await cook(raw, undefined);
    if (this.footerMessage === raw) {
      this.cookedFooterMessage = cooked;
    }
  }

  <template>
    <div
      class="mod-topic-footer-message-outlet"
      {{didInsert this.refreshOnNavigation}}
      {{didUpdate this.refreshOnNavigation this.topic.id}}
    >
      {{#if this.showPinnedCopy}}
        <div class="topic-footer-pinned-post">
          <article class="pinned-post">
            {{#if this.pinnedAvatarUrl}}
              <img
                alt=""
                class="pinned-post-avatar"
                height="45"
                src={{this.pinnedAvatarUrl}}
                width="45"
              />
            {{/if}}
            <div class="pinned-post-main">
              <div class="pinned-post-header">
                <span class="pinned-post-username">
                  {{this.pinnedPost.username}}
                </span>
                <span
                  class="pinned-post-badge"
                  title={{i18n
                    "discourse_mod_categories.pin_post.pinned_label"
                  }}
                >
                  {{icon "thumbtack"}}
                  {{i18n "discourse_mod_categories.pin_post.pinned_label"}}
                </span>
                {{#if this.originalPostUrl}}
                  <a
                    class="pinned-post-jump"
                    href={{this.originalPostUrl}}
                    title={{i18n
                      "discourse_mod_categories.pin_post.jump_to_original"
                    }}
                  >
                    {{icon "arrow-up"}}
                  </a>
                {{/if}}
              </div>
              <div
                class="cooked"
                {{didInsert this.markDirections}}
                {{didUpdate this.markDirections this.pinnedPostHtml}}
              >{{this.pinnedPostHtml}}</div>
            </div>
          </article>
        </div>
      {{/if}}
      {{#if this.footerMessage}}
        <div class="topic-footer-message">
          <div class="topic-footer-message-icon">
            {{icon "shield-halved"}}
          </div>
          <div class="topic-footer-message-body">
            <div class="topic-footer-message-label">
              {{i18n "discourse_mod_categories.footer_message.label"}}
            </div>
            <div
              class="topic-footer-message-content cooked"
              {{didInsert this.markDirections}}
              {{didUpdate this.markDirections this.messageHtml}}
            >
              {{this.messageHtml}}
            </div>
          </div>
        </div>
      {{/if}}
    </div>
  </template>
}
