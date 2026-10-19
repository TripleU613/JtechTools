import Component from "@glimmer/component";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { settings, themePrefix } from "virtual:theme";
import type Post from "discourse/models/post";
import type SiteSettingsService from "discourse/services/site-settings";
import DButton from "discourse/ui-kit/d-button";
import { printPost, type PrintTopic } from "../lib/jt-print.ts";

type PrintablePost = Post & {
  post_number: number;
  topic?: PrintTopic & {
    category_id?: number;
    category?: { parent_category_id?: number };
  };
};

interface JtPrintPostSignature {
  Args: {
    post: PrintablePost;
    showLabel?: boolean;
  };
  Element: HTMLButtonElement | HTMLAnchorElement;
}

const categoryIds = () =>
  settings.print_button_categories.split("|").filter(Boolean).map(Number);

// Print in a topic's first post menu, for topics in print_button_categories
// or their subcategories (lib/jt-print). The first post is where the topic
// opens, on phones too; core's footer buttons only show once the last post
// has loaded.
export default class JtPrintPost extends Component<JtPrintPostSignature> {
  static shouldRender({ post }: { post: PrintablePost }) {
    const topic = post.topic;
    if (post.post_number !== 1 || !topic) {
      return false;
    }
    const ids = categoryIds();
    return [topic.category_id, topic.category?.parent_category_id].some(
      (id) => id !== undefined && ids.includes(id)
    );
  }

  @service declare siteSettings: SiteSettingsService & { title: string };

  @action
  print() {
    const { post } = this.args;
    if (post.topic) {
      printPost(post, post.topic, this.siteSettings.title);
    }
  }

  <template>
    <DButton
      class="post-action-menu__jt-print"
      ...attributes
      @action={{this.print}}
      @ariaLabel={{themePrefix "jt.print.title"}}
      @icon="print"
      @label={{if @showLabel (themePrefix "jt.print.label")}}
      @title={{themePrefix "jt.print.title"}}
    />
  </template>
}
