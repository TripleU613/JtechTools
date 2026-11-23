import { withPluginApi } from "discourse/lib/plugin-api";
import type {
  default as JtLinesService,
  JtLines,
} from "../services/jt-lines.ts";

interface ListResult {
  topic_list?: { jt_lines?: JtLines | null } | null;
  category_list?: { jt_lines?: JtLines | null } | null;
}

// The lines come inside the welcome pages' own lists (sub_plugins/ads.rb):
// Latest's topic list, the Categories page's category list. Every way core
// turns such a response into a list passes through one of these two, before
// the page renders, so the welcome area has them as it draws.
export default {
  name: "jt-l-lists",

  initialize() {
    withPluginApi((api) => {
      const lines = api.container.lookup("service:jt-lines") as JtLinesService;

      api.registerValueTransformer(
        "topic-list-topics-from",
        ({
          value,
          context,
        }: {
          value: unknown;
          context: { result?: ListResult };
        }) => {
          lines.take(context.result?.topic_list?.jt_lines);
          return value;
        }
      );

      api.registerValueTransformer(
        "category-list-attributes",
        ({
          value,
          context,
        }: {
          value: unknown;
          context: { result?: ListResult };
        }) => {
          lines.take(context.result?.category_list?.jt_lines);
          return value;
        }
      );
    });
  },
};
