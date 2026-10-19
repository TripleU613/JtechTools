import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import JtPrintPost from "../components/jt-print-post.gts";

interface PostMenuDag {
  add(key: string, value: unknown, position?: { after?: string }): void;
}

// Print on the first post of topics in print_button_categories (it replaces
// the Topic PDF Download Button component). The button decides per post.
export default apiInitializer((api) => {
  if (!settings.print_button_categories) {
    return;
  }
  api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag }: { value: PostMenuDag }) => {
      dag.add("jt-print", JtPrintPost, { after: "copyLink" });
    }
  );
});
