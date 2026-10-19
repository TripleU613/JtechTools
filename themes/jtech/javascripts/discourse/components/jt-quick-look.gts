import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import type Owner from "@ember/owner";
import { type TrustedHTML, trustHTML } from "@ember/template";
import type { ComponentLike } from "@glint/template";
import { themePrefix } from "virtual:theme";
import { ajax } from "discourse/lib/ajax";
import type Topic from "discourse/models/topic";
import { gt } from "discourse/truth-helpers";
import DConditionalLoadingSpinner from "discourse/ui-kit/d-conditional-loading-spinner";
import DDecoratedHtml from "discourse/ui-kit/d-decorated-html";
import DModalBase from "discourse/ui-kit/d-modal";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";
import dFormatDate from "discourse/ui-kit/helpers/d-format-date";
import { i18n } from "discourse-i18n";
import { categoryLinkHTML } from "../lib/jt-core-helpers.ts";

// DModal declares @title as a plain string, but renders whatever it gets;
// the title here is trusted HTML (see `title` below).
const DModal = DModalBase as unknown as ComponentLike<{
  Element: HTMLDivElement | HTMLFormElement;
  Args: {
    closeModal?: () => void;
    title?: string | TrustedHTML;
  };
  Blocks: { belowModalTitle: []; body: []; footer: [] };
}>;

type QuickLookTopic = Topic & { id: number };

// GET /posts/by_number/:topic_id/1.json, as far as this modal reads it.
interface QuickLookPost {
  cooked: string;
  username: string;
  name?: string | null;
  avatar_template: string;
  created_at: string;
}

interface JtQuickLookSignature {
  Args: {
    model: { topic: QuickLookTopic };
    closeModal: () => void;
  };
}

// First post of a topic in a modal. Fetches the post alone (not /t/:id.json)
// so previewing doesn't count as a visit or change the topic's new/unread
// state. Cooked HTML goes through DDecoratedHtml so registered decorators
// (lightbox, spoilers, external-link marks…) run like they do in the stream.
export default class JtQuickLook extends Component<JtQuickLookSignature> {
  @tracked post: QuickLookPost | null = null;
  @tracked failed = false;

  constructor(owner: Owner, args: JtQuickLookSignature["Args"]) {
    super(owner, args);
    this.load();
  }

  get topic(): QuickLookTopic {
    return this.args.model.topic;
  }

  // fancy_title is the server-escaped title with emoji, as TopicLink shows it
  get title(): TrustedHTML {
    return trustHTML(this.topic.fancyTitle || "");
  }

  get cooked(): TrustedHTML {
    return trustHTML(this.post?.cooked || "");
  }

  async load(): Promise<void> {
    try {
      this.post = await ajax(`/posts/by_number/${this.topic.id}/1.json`);
    } catch {
      this.failed = true;
    }
  }

  <template>
    <DModal
      class="jt-quick-look"
      @closeModal={{@closeModal}}
      @title={{this.title}}
    >
      <:belowModalTitle>
        <div class="jt-quick-look__category">{{categoryLinkHTML
            this.topic.category
          }}</div>
      </:belowModalTitle>
      <:body>
        {{#if this.failed}}
          <p class="jt-quick-look__error">{{i18n
              (themePrefix "jt.quick_look_error")
            }}</p>
        {{else}}
          <DConditionalLoadingSpinner @condition={{if this.post false true}}>
            <div class="jt-quick-look__author">
              {{dAvatar this.post imageSize="small"}}
              <span class="jt-quick-look__name">{{this.post.username}}</span>
              <span class="jt-quick-look__date">{{dFormatDate
                  this.post.created_at
                  format="medium"
                }}</span>
            </div>
            <DDecoratedHtml
              @className="cooked jt-quick-look__cooked"
              @html={{this.cooked}}
            />
          </DConditionalLoadingSpinner>
        {{/if}}
      </:body>
      <:footer>
        <a
          class="btn btn-primary"
          href={{this.topic.url}}
          {{on "click" @closeModal}}
        >{{i18n (themePrefix "jt.open_topic")}}</a>
        {{#if (gt this.topic.replyCount 0)}}
          <a
            class="btn btn-default"
            href={{this.topic.lastPostUrl}}
            {{on "click" @closeModal}}
          >{{i18n (themePrefix "jt.latest_reply")}}</a>
        {{/if}}
      </:footer>
    </DModal>
  </template>
}
