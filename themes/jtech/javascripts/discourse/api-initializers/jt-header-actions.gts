import type { TemplateOnlyComponent } from "@ember/component/template-only";
import type { ComponentLike } from "@glint/template";
import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type InterfaceColor from "discourse/services/interface-color";
import JtHeaderIcon, {
  type JtHeaderIconKind,
} from "../components/jt-header-icon.gts";
import JtHeaderNewTopic from "../components/jt-header-new-topic.gts";
import JtHeaderSearch from "../components/jt-header-search.gts";
import { colorToggleAvailable } from "../lib/jt-color-mode.ts";

type HeaderUser = User & { can_send_private_messages?: boolean };

interface JtCenteredSignature {
  Args: { outletArgs?: Record<string, unknown> };
}

// Header right, in order: search field (command menu) · JTech home ·
// messages · notifications · light/dark (header_color_toggle) · new topic ·
// avatar. Core's magnifier stays in the DOM, hidden while the search field
// shows (jt-header.scss), so "/" still opens core's search.
// The same field for the middle of the header on wide screens. It goes in
// before-header-panel, outside core's icon panel, which core's menus are
// positioned against, so it can be centred on the whole bar.
const JtCenteredSearch: TemplateOnlyComponent<JtCenteredSignature> = <template>
  <JtHeaderSearch @centered={{true}} />
</template>;

const icon = (
  kind: JtHeaderIconKind,
  extra: { href?: string } = {}
): TemplateOnlyComponent => <template>
  <JtHeaderIcon @href={{extra.href}} @kind={{kind}} />
</template>;

export default apiInitializer((api) => {
  const user: HeaderUser | null = api.getCurrentUser();
  const site = api.container.lookup("service:site") as Site & {
    can_search: boolean;
  };
  const interfaceColor = api.container.lookup(
    "service:interface-color"
  ) as InterfaceColor;
  let previous = "search";
  const add = (key: string, component: ComponentLike) => {
    api.headerIcons.add(key, component, {
      after: previous,
      before: "hamburger",
    });
    previous = key;
  };

  // The field replaces core's magnifier only when there's something to open:
  // the command menu, for visitors allowed to search.
  if (settings.command_menu && site.can_search) {
    document.documentElement.classList.add("jt-has-header-search");
    api.headerIcons.add("jt-search", JtHeaderSearch, { before: "search" });
    api.renderInOutlet("before-header-panel", JtCenteredSearch);
  }
  if (settings.header_home_url) {
    add("jt-home", icon("home", { href: settings.header_home_url }));
  }
  if (user?.can_send_private_messages) {
    add("jt-messages", icon("messages"));
  }
  if (user) {
    add("jt-notifications", icon("notifications"));
  }
  // Off unless asked for (header_color_toggle): the sidebar's Color mode menu
  // and the command menu already switch, and the bar is full enough. Without
  // the icon, core's header selector is left alone if a site turns it on.
  if (settings.header_color_toggle && colorToggleAvailable(interfaceColor)) {
    document.documentElement.classList.add("jt-has-color-toggle");
    add("jt-theme", icon("theme"));
  }
  add("jt-new-topic", JtHeaderNewTopic);
});
