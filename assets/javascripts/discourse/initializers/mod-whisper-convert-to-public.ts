import type Owner from "@ember/owner";
import type DialogService from "discourse/dialog-holder/services/dialog";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { withPluginApi } from "discourse/lib/plugin-api";
import type User from "discourse/models/user";
import type SiteSettings from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";
import type { WhisperPostFields } from "../lib/mod-whisper-reply-audience.ts";

interface ConvertToPublicSiteSettings {
  mod_whisper_enabled: boolean;
  mod_whisper_convert_enabled: boolean;
}

// `set` is absent on a plain (non-model) post object.
type ConvertiblePost = WhisperPostFields & {
  id: number;
  set?: (key: string, value: unknown) => unknown;
};

interface WhisperStateResponse {
  mod_is_whisper: boolean;
}

// Adds a "Convert to public post" button to a whisper post's admin menu —
// staff-only, visible only while the post is currently armed as a whisper.
// Calls the existing PUT /discourse-mod-categories/post/:id/whisper endpoint
// with mod_whisper:false so the post immediately stops being a whisper and
// becomes visible to everyone who can read the topic.
//
// The composer toolbar route (edit post → eye button → Clear → save) still
// works; this button is the discoverable equivalent for the case a staff
// member only wants to flip the visibility without editing the body — e.g.
// after a topic move where a whisper-only post is now in the wrong place.
export default {
  name: "discourse-mod-whisper-convert-to-public",

  initialize(container: Owner) {
    const currentUser = container.lookup("service:current-user") as User | null;
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & ConvertToPublicSiteSettings;
    const dialog = container.lookup("service:dialog") as DialogService;

    if (
      !currentUser ||
      !currentUser.staff ||
      !siteSettings.mod_whisper_enabled ||
      !siteSettings.mod_whisper_convert_enabled
    ) {
      return;
    }

    withPluginApi((api) => {
      api.addPostAdminMenuButton((post: ConvertiblePost) => {
        if (!post?.mod_is_whisper) {
          return;
        }

        return {
          icon: "far-eye",
          className: "mod-whisper-convert-to-public",
          label: "discourse_mod_categories.whisper.convert_to_public.label",
          title: "discourse_mod_categories.whisper.convert_to_public.title",
          action: () => {
            dialog.confirm({
              message: i18n(
                "discourse_mod_categories.whisper.convert_to_public.confirm"
              ),
              didConfirm: () =>
                ajax(`/discourse-mod-categories/post/${post.id}/whisper`, {
                  type: "PUT",
                  data: { mod_whisper: false },
                })
                  .then((res: WhisperStateResponse | null) => {
                    // Push the new state onto the post so the cooked-element
                    // decorator strips the banner without a topic reload.
                    if (post.set) {
                      post.set("mod_is_whisper", res?.mod_is_whisper);
                      post.set("mod_whisper_target_user_ids", []);
                      post.set("mod_whisper_target_group_ids", []);
                      post.set("mod_whisper_target_badge_ids", []);
                      post.set("mod_whisper_targets", []);
                      post.set("mod_whisper_target_groups", []);
                      post.set("mod_whisper_target_badges", []);
                      post.set("mod_whisper_is_staff_only", false);
                    }
                  })
                  .catch(popupAjaxError),
            });
          },
        };
      });
    });
  },
};
