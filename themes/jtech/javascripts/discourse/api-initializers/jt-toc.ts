import { settings, themePrefix } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
import {
  depth,
  headingsIn,
  MIN_HEADINGS,
  TOC_MARKER,
  tocApplies,
} from "../lib/jt-toc.ts";

interface TocPostModel {
  post_number?: number;
  topic?: { category?: { id?: number; parent_category_id?: number } };
}

interface ComposerLike {
  model?: { creatingTopic?: boolean; editingFirstPost?: boolean };
}

// Contents for a first post (setting table_of_contents; DiscoTOC's
// replacement): where there's no timeline (phones, narrow windows) a card in
// the post, at DiscoTOC's marker or at the top, folded until opened. Desktop
// shows connectors/topic-navigation/jt-toc instead, and the card hides there.
// Its links are the headings' own anchors, which core jumps to.
export default apiInitializer((api) => {
  if (!settings.table_of_contents) {
    return;
  }

  api.decorateCookedElement(
    (cooked: HTMLElement, helper?: { getModel?: () => TocPostModel }) => {
      const post = helper?.getModel?.();
      if (post?.post_number !== 1 || cooked.querySelector(".jt-toc-inline")) {
        return;
      }
      const marker = cooked.querySelector<HTMLElement>(
        '[data-theme-toc="true"]'
      );
      if (!tocApplies(!!marker, post.topic?.category)) {
        return;
      }
      const headings = headingsIn(cooked);
      if (headings.length < MIN_HEADINGS) {
        return;
      }

      const card = document.createElement("details");
      card.className = "jt-toc-inline";
      const summary = document.createElement("summary");
      summary.textContent = i18n(themePrefix("jt.toc.title"));
      const list = document.createElement("ol");
      list.className = "jt-toc__list";
      for (const heading of headings) {
        const item = document.createElement("li");
        item.className = "jt-toc__item";
        item.style.setProperty(
          "--jt-toc-depth",
          String(depth(heading, headings))
        );
        const link = document.createElement("a");
        link.className = "jt-toc__link";
        link.href = `#${heading.anchor}`;
        link.textContent = heading.text;
        item.append(link);
        list.append(item);
      }
      card.append(summary, list);
      if (marker) {
        marker.replaceChildren(card);
      } else {
        cooked.prepend(card);
      }
    },
    { id: "jt-toc", onlyStream: true }
  );

  api.addComposerToolbarPopupMenuOption({
    action: (toolbarEvent: { addText: (text: string) => void }) => {
      toolbarEvent.addText(`${TOC_MARKER}\n\n`);
    },
    icon: "list",
    label: themePrefix("jt.toc.insert"),
    condition: (composer: ComposerLike) =>
      !!(composer.model?.creatingTopic || composer.model?.editingFirstPost),
  });
});
