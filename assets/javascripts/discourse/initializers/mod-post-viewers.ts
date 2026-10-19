import type Owner from "@ember/owner";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { withPluginApi } from "discourse/lib/plugin-api";
import type User from "discourse/models/user";
import type ModalService from "discourse/services/modal";
import type SiteSettings from "discourse/services/site-settings";
import ModPostViewers, {
  type PostViewersResponse,
} from "../components/mod-post-viewers.gts";

interface PostViewersSiteSettings {
  mod_categories_enabled: boolean;
}

// Staff action on forum posts: "See message viewers" — who has read this
// post (core post_timings) and when they last visited the topic.
export default {
  name: "mod-post-viewers",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettings & PostViewersSiteSettings;
    const currentUser = container.lookup("service:current-user") as User | null;
    if (!siteSettings.mod_categories_enabled || !currentUser?.staff) {
      return;
    }

    withPluginApi((api) => {
      api.addPostAdminMenuButton((post: { id: number }) => {
        return {
          icon: "eye",
          className: "mod-post-viewers-button",
          label: "discourse_mod_categories.post_viewers.label",
          action: async () => {
            try {
              const data: PostViewersResponse = await ajax(
                `/discourse-mod-categories/post/${post.id}/viewers`
              );
              const modal = container.lookup("service:modal") as ModalService;
              modal.show(ModPostViewers, {
                model: { count: data.count, viewers: data.viewers },
              });
            } catch (error) {
              popupAjaxError(error);
            }
          },
        };
      });
    });
  },
};
