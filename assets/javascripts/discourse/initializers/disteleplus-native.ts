import type Owner from "@ember/owner";
import { withPluginApi } from "discourse/lib/plugin-api";
import DisteleplusHeaderIcon from "../components/disteleplus-header-icon";
import DisteleplusService, {
  DisteleplusCurrentUser,
  DisteleplusSiteSettings,
} from "../services/disteleplus";

export default {
  name: "disteleplus-native",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as DisteleplusSiteSettings;
    const currentUser = container.lookup(
      "service:current-user"
    ) as DisteleplusCurrentUser | null;
    if (
      !siteSettings.disteleplus_enabled ||
      !currentUser?.can_access_disteleplus
    ) {
      return;
    }

    withPluginApi((api) => {
      api.headerIcons.add("disteleplus", DisteleplusHeaderIcon, {
        after: "search",
        before: "hamburger",
      });
      // Unread mentions count in the browser tab title, as on the header badge.
      const disteleplus = container.lookup(
        "service:disteleplus"
      ) as DisteleplusService;
      api.addDocumentTitleCounter(() => disteleplus.unreadMentionCount || 0);
    });
  },
};
