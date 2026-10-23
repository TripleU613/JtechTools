import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import DiscourseURL from "discourse/lib/url";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type InterfaceColor from "discourse/services/interface-color";
import type SiteSettingsService from "discourse/services/site-settings";
import I18n from "discourse-i18n";
import { colorToggleAvailable, toggleColorMode } from "../lib/jt-color-mode.ts";
import { jtLabel } from "../lib/jt-labels.ts";
import { JT_SHORTCUTS } from "../lib/jt-shortcuts.ts";

type ShortcutName = keyof typeof JT_SHORTCUTS;

// Core's help dialog (?) names a shortcut by a key under
// keyboard_shortcuts_help; a theme's strings live elsewhere, so the menu's
// own labels are copied there.
function addHelpLabels(names: ShortcutName[]) {
  const js = I18n.translations[I18n.currentLocale()]?.js;
  if (!js?.keyboard_shortcuts_help) {
    return;
  }
  js.keyboard_shortcuts_help.jtech = Object.fromEntries(
    names.map((name) => [name, jtLabel(`cmdk.${name}`)])
  );
}

// The command menu's commands that core has no key for (lib/jt-shortcuts):
// tags, notifications, preferences, admin, light / dark and advanced search.
// Like core's own keys, they don't fire while typing in a field.
export default apiInitializer((api) => {
  if (!settings.command_menu) {
    return;
  }
  const user = api.getCurrentUser() as User | null;
  const siteSettings = api.container.lookup(
    "service:site-settings"
  ) as SiteSettingsService & { tagging_enabled: boolean };
  const interfaceColor = api.container.lookup(
    "service:interface-color"
  ) as InterfaceColor;
  const site = api.container.lookup("service:site") as Site & {
    can_search: boolean;
  };

  // and the browser's own use of the keys, if any, left out
  const go = (url: string) => (event?: KeyboardEvent) => {
    event?.preventDefault();
    DiscourseURL.routeTo(url, undefined);
  };
  const added: ShortcutName[] = [];
  const add = (
    name: ShortcutName,
    callback: (event?: KeyboardEvent) => unknown,
    category: "jump_to" | "application",
    anonymous = false
  ) => {
    const keys: string = JT_SHORTCUTS[name];
    const [first, then] = keys.split(" ");
    api.addKeyboardShortcut(keys, callback, {
      anonymous,
      help: {
        category,
        name: `jtech.${name}`,
        // one key, then the next (as core shows "shift+z shift+z"); a single
        // group of ["g", "g"] would show one G. Keys held together are one
        // group, as core's [mod, p].
        definition: then
          ? { keys1: [first], keys2: [then], shortcutsDelimiter: "space" }
          : { keys1: first.split("+") },
      },
    });
    added.push(name);
  };

  if (siteSettings.tagging_enabled) {
    add("tags", go("/tags"), "jump_to", true);
  }
  if (user) {
    add("notifications", go("/my/notifications"), "jump_to");
    add("preferences", go("/my/preferences"), "jump_to");
  }
  if (user?.staff) {
    add("admin", go("/admin"), "jump_to");
  }
  if (colorToggleAvailable(interfaceColor)) {
    add(
      "toggle_theme",
      () => toggleColorMode(interfaceColor),
      "application",
      true
    );
  }
  if (site.can_search) {
    add("advanced_search", go("/search?expanded=true"), "application", true);
  }
  addHelpLabels(added);
});
