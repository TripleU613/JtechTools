import Component from "@glimmer/component";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import DButton from "discourse/components/d-button";
import type { ListingTopicFields } from "../../lib/listing-format.ts";

type ListingTopic = ListingTopicFields & {
  details?: { can_create_post?: boolean };
};

interface TopicController {
  replyToPost: () => Promise<unknown>;
}

interface ListingFormatCreateSignature {
  Args: { outletArgs: { model?: ListingTopic | null } };
}

// The one way to post in a listing topic: a centered Create listing button
// at the bottom, in place of Reply (hidden by the stylesheet while this is
// on the page). Only for people who have to follow the format.
export default class ListingFormatCreate extends Component<ListingFormatCreateSignature> {
  get show(): boolean {
    const topic = this.args.outletArgs?.model;
    return (
      !!topic?.listing_format_fields?.length && !!topic.details?.can_create_post
    );
  }

  // Core's own Reply action, so drafts open the same way.
  @action
  create() {
    const topic = getOwner(this)?.lookup("controller:topic") as unknown as
      | TopicController
      | undefined;
    topic?.replyToPost().catch(() => {});
  }

  <template>
    {{#if this.show}}
      <div class="listing-format-create">
        <DButton
          class="btn-primary btn-large listing-format-create__button"
          @action={{this.create}}
          @icon="plus"
          @label="listing_format.create.label"
        />
      </div>
    {{/if}}
  </template>
}
