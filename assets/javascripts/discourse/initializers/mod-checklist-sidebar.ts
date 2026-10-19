import type Owner from "@ember/owner";
import { withPluginApi } from "discourse/lib/plugin-api";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import ModChecklistModal from "../components/mod-checklist-modal.gts";

interface ChecklistSidebarSiteSettings {
  mod_categories_enabled: boolean;
  mod_first_post_checklist_enabled: boolean;
}

// Adds a "First-post checklist" link to the sidebar Community section
// (staff only). The link opens the checklist config in a modal — section
// links can only navigate, so the link renders with an inert href and a
// delegated click handler opens the modal instead.
export default {
  name: "discourse-mod-checklist-sidebar",

  initialize(container: Owner) {
    const currentUser = container.lookup("service:current-user") as User | null;
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & ChecklistSidebarSiteSettings;
    if (
      !siteSettings.mod_categories_enabled ||
      !siteSettings.mod_first_post_checklist_enabled
    ) {
      return;
    }
    if (!currentUser?.staff) {
      return;
    }

    withPluginApi((api) => {
      api.addCommunitySectionLink({
        name: "mod-checklist",
        href: "#",
        title: i18n(
          "discourse_mod_categories.first_post_checklist.sidebar_title"
        ),
        text: i18n(
          "discourse_mod_categories.first_post_checklist.sidebar_text"
        ),
        icon: "list-check",
      });
    });

    const modal = container.lookup("service:modal") as ModalService;
    document.addEventListener("click", (event) => {
      const link = (event.target as Element).closest(
        '[data-list-item-name="mod-checklist"]'
      );
      if (!link) {
        return;
      }
      event.preventDefault();
      modal.show(ModChecklistModal, undefined);
    });
  },
};
