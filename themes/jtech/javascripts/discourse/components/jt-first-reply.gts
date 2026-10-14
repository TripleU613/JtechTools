import Component from "@glimmer/component";
import { settings, themePrefix } from "virtual:theme";
import type Topic from "discourse/models/topic";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";

type FirstReplyTopic = Topic & {
  archetype: string;
  category_id: number;
};

interface FirstReplyPost {
  post_number: number;
  topic?: FirstReplyTopic | null;
}

interface JtFirstReplySignature {
  Args: { outletArgs: { post: FirstReplyPost } };
}

// "Be the first to reply" under a topic's opening post while it has no
// replies and the reader can reply. Not in messages or the hidden categories.
export default class JtFirstReply extends Component<JtFirstReplySignature> {
  static shouldRender(args: { post?: FirstReplyPost | null }): boolean {
    const post = args.post;
    const topic = post?.topic;
    if (!settings.first_reply_prompt || post?.post_number !== 1 || !topic) {
      return false;
    }
    if (topic.archetype === "private_message" || topic.posts_count !== 1) {
      return false;
    }
    if (!topic.details?.can_create_post) {
      return false;
    }
    const hidden = (settings.first_reply_prompt_hidden_categories || "")
      .split("|")
      .filter(Boolean)
      .map(Number);
    return !hidden.includes(topic.category_id);
  }

  <template>
    <div class="jt-first-reply">
      <span class="jt-first-reply__icon">{{dIcon "far-comment"}}</span>
      <span>{{i18n (themePrefix "jt.first_reply.title")}}</span>
    </div>
  </template>
}
