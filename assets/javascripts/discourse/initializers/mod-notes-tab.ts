import type Owner from "@ember/owner";
import { withPluginApi } from "discourse/lib/plugin-api";
import type UserMenuTab from "discourse/lib/user-menu/tab";
import type User from "discourse/models/user";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import ModNotesPanel from "../components/mod-notes-panel.gts";

interface NotesTabSiteSettings {
  mod_categories_enabled: boolean;
  mod_notes_feed_enabled: boolean;
}

type NotesTabUser = User & { mod_note_unread_count?: number };

// Registers a staff-only "Moderator notes" tab in the user menu, with the
// shield icon and an unread count, alongside the bell and other tabs.
export default {
  name: "discourse-mod-notes-tab",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & NotesTabSiteSettings;
    if (
      !siteSettings.mod_categories_enabled ||
      !siteSettings.mod_notes_feed_enabled
    ) {
      return;
    }

    withPluginApi((api) => {
      const tabFactory = (Base: typeof UserMenuTab) => {
        return class extends Base {
          declare currentUser: NotesTabUser | null;

          get id() {
            return "discourse-mod-notes";
          }

          get panelComponent() {
            return ModNotesPanel;
          }

          get icon() {
            return "shield-halved";
          }

          get title() {
            return i18n("discourse_mod_categories.notes_tab.title");
          }

          get shouldDisplay() {
            return !!this.currentUser?.staff;
          }

          get count() {
            return this.currentUser?.mod_note_unread_count || 0;
          }
        };
      };
      // Core types the tab callback as instance -> instance; it really
      // receives and returns the class.
      api.registerUserMenuTab(
        tabFactory as unknown as Parameters<typeof api.registerUserMenuTab>[0]
      );
    });
  },
};
