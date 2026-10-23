import type Owner from "@ember/owner";
import { apiInitializer } from "discourse/lib/api";
import { helperContext } from "discourse/lib/helpers";
import type Site from "discourse/models/site";
import JtPostMenuMore from "../components/jt-post-menu-more.gts";
import JtPostMenuRoom from "../components/jt-post-menu-room.gts";
import { buttonsIn, menuRoom } from "../lib/jt-post-menu-room.ts";

// The buttons a post's menu keeps on its line on a phone, the most wanted
// first. The rest go into ⋯ the other way round: delete first, edit last.
const KEEP = [
  "edit",
  "solved",
  "copyLink",
  "translate",
  "addTranslation",
  "jt-copy-post",
  "jt-print",
  "bookmark",
  "share",
  "read",
  "flag",
  "admin",
  "delete",
];
// a plugin's button not listed: about as wanted as Share
const UNLISTED = KEEP.indexOf("share");
// always on the line: liking, reacting, replying, and ⋯ itself
const ALWAYS = new Set([
  "like",
  "reply",
  "showMore",
  "jt-reaction-rollout",
  "jt-post-menu-room",
]);

type ButtonClass = Record<string, unknown>;

interface MenuDag {
  add(key: string, value: unknown): boolean;
  replace(key: string, value: unknown): boolean;
  entries: () => [string, ButtonClass, unknown][];
}

interface MenuContext {
  post: { id: number; reactions?: unknown[] };
  state: unknown;
  buttonKeys: { SHOW_MORE: string } & Record<string, string>;
  collapsedButtons: { hide(key: string): void };
  buttonLabels: { show(key: string): void };
}

// A button's static shouldRender / extraControls, as the menu reads them
function staticValue(
  klass: ButtonClass,
  property: string,
  args: unknown,
  owner: Owner,
  fallback: boolean
): boolean {
  const value = klass?.[property];
  if (typeof value === "function") {
    return !!value.call(klass, args, helperContext(), owner);
  }
  return value === undefined ? fallback : !!value;
}

// A post's menu on a phone, on one line: the buttons that don't fit go into
// ⋯, which lists them (components/jt-post-menu-more), least wanted first,
// with what the forum keeps there anyway (post_menu_hidden_items). How many
// fit is measured on the page (components/jt-post-menu-room).
export default apiInitializer((api) => {
  const owner = api.container as unknown as Owner;
  const site = owner.lookup("service:site") as Site;
  const siteSettings = owner.lookup("service:site-settings") as unknown as {
    post_menu: string;
    post_menu_hidden_items: string;
  };

  api.registerValueTransformer(
    "post-menu-buttons",
    ({ value: dag, context }: { value: MenuDag; context: MenuContext }) => {
      if (!site.mobileView) {
        return;
      }
      const { buttonKeys } = context;
      dag.replace(buttonKeys.SHOW_MORE, JtPostMenuMore);
      dag.add("jt-post-menu-room", JtPostMenuRoom);

      // Plugins add their buttons (Solution, translate, the reactions) in
      // their own transformers, which may run after this one. The menu reads
      // the list once they all have: that's when what goes where is decided.
      const entries = dag.entries.bind(dag);
      dag.entries = () => {
        const all = entries();
        fit(all, context);
        return all;
      };
    }
  );

  function fit(all: [string, ButtonClass, unknown][], context: MenuContext) {
    const { post, state, buttonKeys, collapsedButtons, buttonLabels } = context;
    // core's buttons are on the menu only as the forum sets it (post_menu)
    const core = new Set(Object.values(buttonKeys));
    const configured = new Set(siteSettings.post_menu.split("|"));
    const args = { post, state };
    // the buttons this post shows on its line, by key
    const shown = all
      .filter(
        ([key, klass]) =>
          key !== "jt-post-menu-room" &&
          key !== buttonKeys.SHOW_MORE &&
          (!core.has(key) || configured.has(key)) &&
          !staticValue(klass, "extraControls", args, owner, false) &&
          staticValue(klass, "shouldRender", args, owner, true)
      )
      .map(([key]) => key);

    // until it's measured: the screen's width, less the reactions beside
    // the buttons if there are any
    const room =
      menuRoom.get(post.id) ??
      buttonsIn(window.innerWidth - 22 - (post.reactions?.length ? 72 : 0));

    const hidden = new Set(siteSettings.post_menu_hidden_items.split("|"));
    const into = shown.filter((key) => hidden.has(key) && !ALWAYS.has(key));
    const rank = (key: string) => {
      const at = KEEP.indexOf(key);
      return at < 0 ? UNLISTED : at;
    };
    const spare = shown
      .filter((key) => !ALWAYS.has(key) && !into.includes(key))
      .sort((a, b) => rank(b) - rank(a));
    // ⋯ takes a place once there's anything in it
    const onLine = () => shown.length - into.length + (into.length ? 1 : 0);
    while (onLine() > room && spare.length) {
      into.push(spare.shift()!);
    }

    // ⋯ shows from two (core puts one back on the line, as it is there)
    if (into.length > 1) {
      for (const key of into) {
        collapsedButtons.hide(key);
        buttonLabels.show(key);
      }
    }
  }
});
