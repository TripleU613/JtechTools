import { settings, themePrefix } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import { avatarUrl } from "discourse/lib/avatar-utils";
import { i18n } from "discourse-i18n";

interface OnlineUser {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
}

// The parts of the Who's Online plugin's service used here
interface WhosOnline {
  enabled: boolean;
  users?: OnlineUser[];
  count: number;
}

interface OnlineSiteSettings {
  whos_online_minimum_display?: number;
}

// The most people the section lists; its title counts everyone online
const SHOWN = 12;

// Who's Online (the plugin) puts a row of avatars over the topic list, in the
// way of the tabs. With setting sidebar_online it's a sidebar section
// instead, "Online · 8", listing the people online by name with their
// avatars, live; the row over the list is hidden (jt-sidebar.scss). It shows
// to the people the plugin shows its row to, and only while as many people
// are online as the plugin's own minimum.
export default apiInitializer((api) => {
  if (!settings.sidebar_online) {
    return;
  }
  const whosOnline = api.container.lookup("service:whos-online") as
    | WhosOnline
    | undefined;
  if (!whosOnline?.enabled) {
    return;
  }
  const siteSettings = api.container.lookup(
    "service:site-settings"
  ) as OnlineSiteSettings;
  document.documentElement.classList.add("jt-has-online-section");

  api.addSidebarSection(
    (
      BaseCustomSidebarSection: new () => object,
      BaseCustomSidebarSectionLink: new () => object
    ) => {
      class OnlineLink extends BaseCustomSidebarSectionLink {
        user: OnlineUser;
        route = "user";
        prefixType = "image";
        prefixCSSClass = "jt-online__avatar";

        constructor(user: OnlineUser) {
          super();
          this.user = user;
        }

        get name() {
          return `jt-online-${this.user.username}`;
        }

        get models() {
          return [this.user.username];
        }

        get text() {
          return this.user.username;
        }

        get title() {
          return this.user.name || this.user.username;
        }

        get prefixValue() {
          return avatarUrl(this.user.avatar_template, "small");
        }
      }

      return class OnlineSection extends BaseCustomSidebarSection {
        name = "jt-online";

        get text() {
          return i18n(themePrefix("jt.online.title"), {
            count: whosOnline.count,
          });
        }

        get title() {
          return this.text;
        }

        get links() {
          return (whosOnline.users || [])
            .slice(0, SHOWN)
            .map((user) => new OnlineLink(user));
        }

        get displaySection() {
          return (
            whosOnline.count > 0 &&
            whosOnline.count >= (siteSettings.whos_online_minimum_display || 1)
          );
        }
      };
    }
  );
});
