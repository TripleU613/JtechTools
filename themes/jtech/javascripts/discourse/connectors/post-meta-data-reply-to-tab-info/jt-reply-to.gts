import type { TemplateOnlyComponent } from "@ember/component/template-only";
import { themePrefix } from "virtual:theme";
import userPrioritizedName from "discourse/helpers/user-prioritized-name";
import type User from "discourse/models/user";
import dAvatar from "discourse/ui-kit/helpers/d-avatar";
import { i18n } from "discourse-i18n";

interface JtReplyToSignature {
  Args: { outletArgs: { post: { reply_to_user: User } } };
}

// The words in the reply-to tab at a post's top right. Core's are the
// picture and the name alone, which with the tab's small grey type didn't
// read as "this answers an earlier post": now "Replying to", the picture
// and the name (styled in jt-post-chrome.scss).
const JtReplyTo: TemplateOnlyComponent<JtReplyToSignature> = <template>
  <span class="jt-reply-to__label">{{i18n (themePrefix "jt.reply_to")}}</span>
  {{dAvatar @outletArgs.post.reply_to_user imageSize="small"}}
  <span class="jt-reply-to__name">
    {{userPrioritizedName @outletArgs.post.reply_to_user}}
  </span>
</template>;

export default JtReplyTo;
