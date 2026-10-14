import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { themePrefix } from "virtual:theme";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Topic from "discourse/models/topic";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

interface SuggestedTopic {
  unread_posts?: number;
  new_posts?: number;
  unseen?: boolean;
}

interface TrackingState {
  countUnread(): number;
  countNew(): number;
  messageCount: number;
}

interface Dialog {
  yesNoConfirm(options: { message: string; didConfirm: () => void }): void;
}

interface JtDismissUnreadSignature {
  Args: {
    outletArgs: { model: Topic & { suggested_topics?: SuggestedTopic[] } };
  };
}

// Under a topic's "New & Unread Topics", beside "There are 37 unread topics
// remaining": a button that clears them all, as Dismiss does on /unread and
// /new. Without it each one had to be opened to go away. It asks first: read
// state can't be put back.
export default class JtDismissUnread extends Component<JtDismissUnreadSignature> {
  @service declare currentUser: object | null;
  @service declare topicTrackingState: TrackingState;
  @service declare dialog: Dialog;

  @tracked busy = false;

  get count(): number {
    // read so the count follows tracking-state updates, as core's line does
    void this.topicTrackingState.messageCount;
    return this.currentUser
      ? this.topicTrackingState.countUnread() +
          this.topicTrackingState.countNew()
      : 0;
  }

  @action
  confirm() {
    this.dialog.yesNoConfirm({
      message: i18n(themePrefix("jt.dismiss_unread.confirm"), {
        count: this.count,
      }),
      didConfirm: () => this.dismiss(),
    });
  }

  async dismiss() {
    this.busy = true;
    try {
      await Promise.all([
        ajax("/topics/bulk", {
          type: "PUT",
          data: { filter: "unread", operation: { type: "dismiss_posts" } },
        }),
        ajax("/topics/reset-new", {
          type: "PUT",
          data: { dismiss_topics: true, dismiss_posts: true },
        }),
      ]);
      const topic = this.args.outletArgs.model;
      topic.suggested_topics = (topic.suggested_topics ?? []).filter(
        (t) => !t.unread_posts && !t.new_posts && !t.unseen
      );
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.busy = false;
    }
  }

  <template>
    {{#if this.count}}
      <div class="jt-dismiss-unread">
        <DButton
          class="btn-default btn-small jt-dismiss-unread__button"
          @action={{this.confirm}}
          @disabled={{this.busy}}
          @icon="check"
          @translatedLabel={{i18n (themePrefix "jt.dismiss_unread.button")}}
        />
      </div>
    {{/if}}
  </template>
}
