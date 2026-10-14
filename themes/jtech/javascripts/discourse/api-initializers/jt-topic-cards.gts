import type { TemplateOnlyComponent } from "@ember/component/template-only";
import type { ComponentLike } from "@glint/template";
import { settings } from "virtual:theme";
import HeaderTopicCell from "discourse/components/topic-list/header/topic-cell";
import { apiInitializer } from "discourse/lib/api";
import type DAG from "discourse/lib/dag";
import type Category from "discourse/models/category";
import type Topic from "discourse/models/topic";
import JtTopicCard, {
  type JtTopicCardSignature,
} from "../components/jt-topic-card";
import { VANILLA_CLASS } from "../lib/jt-vanilla";

// What core's topic list passes the topic-list-* transformers, as far as
// this file reads it.
interface TopicListContext {
  listContext?: string;
  // discourse-doc-categories
  category?: (Category & { doc_index_topic_id?: number | null }) | null;
}

// The args core's topic-list row gives each column's item cell.
interface TopicListItemCellSignature {
  Args: {
    topic: Topic;
    bulkSelectEnabled?: boolean;
    expandPinned?: boolean;
    hideCategory?: boolean;
    isSelected?: boolean;
    onBulkSelectToggle?: (event: Event) => void;
    showTopicPostBadges?: boolean;
    tagsForUser?: string;
  };
}

interface TopicListColumn {
  header?: ComponentLike;
  item?: ComponentLike<TopicListItemCellSignature>;
}

interface TopicListTransformerArgs<T> {
  value: T;
  context: TopicListContext;
}

interface TopicListItemClickContext {
  event: MouseEvent & { target: Element };
}

// Discovery lists (latest/new/top/category/tag, group + user activity) and
// the messages inbox become cards. Suggested/related lists at the foot of a
// topic stay compact rows, and under a Discourse palette (lib/jt-vanilla)
// every list is stock Discourse's rows.
const CARD_CONTEXTS = [
  "discovery",
  "group-activity",
  "user-activity",
  "messages",
];

const isCardContext = ({ listContext, category }: TopicListContext): boolean =>
  settings.topic_cards &&
  CARD_CONTEXTS.includes(listContext) &&
  !category?.doc_index_topic_id &&
  !document.documentElement.classList.contains(VANILLA_CLASS);

const CardCell: TemplateOnlyComponent<JtTopicCardSignature> = <template>
  <JtTopicCard
    @bulkSelectEnabled={{@bulkSelectEnabled}}
    @hideCategory={{@hideCategory}}
    @isSelected={{@isSelected}}
    @onBulkSelectToggle={{@onBulkSelectToggle}}
    @topic={{@topic}}
  />
</template>;

export default apiInitializer((api) => {
  api.registerValueTransformer(
    "topic-list-class",
    ({ value, context }: TopicListTransformerArgs<string[]>) => {
      if (isCardContext(context)) {
        value.push("jt-cards");
      }
      return value;
    }
  );

  api.registerValueTransformer(
    "topic-list-columns",
    ({ value, context }: TopicListTransformerArgs<DAG<TopicListColumn>>) => {
      if (!isCardContext(context)) {
        return value;
      }
      // bulk-select stays: core's checkbox cell + header select-all keep working
      for (const name of [
        "topic",
        "posters",
        "replies",
        "likes",
        "op-likes",
        "views",
        "activity",
      ]) {
        value.delete(name);
      }
      value.add("jt-card", { header: HeaderTopicCell, item: CardCell });
      return value;
    }
  );

  api.registerValueTransformer(
    "topic-list-item-mobile-layout",
    ({ value, context }: TopicListTransformerArgs<boolean>) =>
      isCardContext(context) ? false : value
  );

  // Click anywhere on the card opens the topic; real links/buttons inside keep
  // their own behaviour. Modifier keys and middle-click open a new tab.
  api.registerBehaviorTransformer(
    "topic-list-item-click",
    ({
      context,
      next,
    }: {
      context: TopicListItemClickContext;
      next: () => void;
    }) => {
      const { event } = context;
      // The list decided whether it's cards (topic-list-class above), so ask it
      // rather than re-deriving that from the topic.
      if (!event.target.closest(".jt-cards")) {
        return next();
      }
      // Selecting text on a card (drag, then release) isn't a click to open it.
      if (window.getSelection()?.toString()) {
        return;
      }
      if (
        (event.target.closest("a, button, input, label") &&
          !event.target.closest(".topic-excerpt")) ||
        event.target.closest(".topic-excerpt-more")
      ) {
        return next();
      }

      const link = event.target
        .closest(".topic-list-item")
        ?.querySelector<HTMLAnchorElement>("a.raw-topic-link");
      if (!link) {
        return next();
      }
      event.preventDefault();
      event.stopPropagation();

      if (event.button === 1) {
        window.open(link.href, "_blank", "noopener,noreferrer");
        return;
      }
      link.dispatchEvent(
        new MouseEvent("click", {
          ctrlKey: event.ctrlKey,
          metaKey: event.metaKey,
          shiftKey: event.shiftKey,
          button: event.button,
          bubbles: true,
          cancelable: true,
        })
      );
    }
  );
});
