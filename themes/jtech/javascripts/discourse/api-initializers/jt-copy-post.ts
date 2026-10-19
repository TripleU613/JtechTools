import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import JtCopyPost from "../components/jt-copy-post.gts";

interface PostMenuDag {
  add(key: string, value: unknown, position?: { after?: string }): void;
}

// A Copy button in each post's menu, beside core's Copy link (setting
// copy_post_button), for the groups in copy_post_groups. Core works out the
// membership server side (resolve_group_membership), so this only reads it.
export default apiInitializer((api) => {
  if (!settings.copy_post_button || !settings.user_in_copy_post_groups) {
    return;
  }
  api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag }: { value: PostMenuDag }) => {
      dag.add("jt-copy-post", JtCopyPost, { after: "copyLink" });
    }
  );
});
