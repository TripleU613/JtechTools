import type Owner from "@ember/owner";
import { withPluginApi } from "discourse/lib/plugin-api";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import ModWhisperAddParticipantModal, {
  type AddParticipantPost,
} from "../components/mod-whisper-add-participant-modal.gts";
import type { WhisperPostFields } from "../lib/mod-whisper-reply-audience.ts";

interface AddParticipantSiteSettings {
  mod_whisper_enabled: boolean;
  mod_whisper_add_participant_enabled: boolean;
}

// Adds an "Add user to whisper" button to a whisper post's admin menu,
// visible only to staff while whispers are enabled. It opens a user chooser
// modal that adds the chosen users to THAT whisper's audience (never to
// other whispers in the topic).
export default {
  name: "discourse-mod-whisper-add-participant",

  initialize(container: Owner) {
    const currentUser = container.lookup("service:current-user") as User | null;
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & AddParticipantSiteSettings;

    if (
      !currentUser ||
      !currentUser.staff ||
      !siteSettings.mod_whisper_enabled ||
      !siteSettings.mod_whisper_add_participant_enabled
    ) {
      return;
    }

    const modal = container.lookup("service:modal") as ModalService;

    withPluginApi((api) => {
      api.addPostAdminMenuButton(
        (post: AddParticipantPost & WhisperPostFields) => {
          if (!post?.mod_is_whisper) {
            return;
          }

          return {
            icon: "user-plus",
            className: "mod-whisper-add-participant",
            label:
              "discourse_mod_categories.whisper.add_participant.menu_label",
            action: () =>
              modal.show(ModWhisperAddParticipantModal, { model: { post } }),
          };
        }
      );
    });
  },
};
