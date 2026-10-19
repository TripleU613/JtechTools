import type Owner from "@ember/owner";
import { withPluginApi } from "discourse/lib/plugin-api";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import ModTopicPromptChecklistModal, {
  type PromptChecklistTopic,
} from "../components/mod-topic-prompt-checklist-modal.gts";

interface PromptChecklistAdminSiteSettings {
  mod_categories_enabled: boolean;
  mod_topic_prompt_checklist_enabled: boolean;
}

// Adds a dedicated "Prompt Checklist" entry to the topic admin (wrench)
// menu, separate from the "Moderator Actions" entry. Visible only to
// staff. Opens its own editor modal scoped to the current topic.
export default {
  name: "discourse-mod-topic-prompt-checklist-admin",

  initialize(container: Owner) {
    const currentUser = container.lookup("service:current-user") as User | null;
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & PromptChecklistAdminSiteSettings;
    if (
      !siteSettings.mod_categories_enabled ||
      !siteSettings.mod_topic_prompt_checklist_enabled
    ) {
      return;
    }
    if (!currentUser || !currentUser.staff) {
      return;
    }

    const modal = container.lookup("service:modal") as ModalService;

    withPluginApi((api) => {
      api.addTopicAdminMenuButton((topic: PromptChecklistTopic) => {
        return {
          icon: "list-check",
          className: "mod-topic-prompt-checklist-button",
          label: "discourse_mod_categories.topic_prompt_checklist.menu_label",
          action: () =>
            modal.show(ModTopicPromptChecklistModal, { model: { topic } }),
        };
      });
    });
  },
};
