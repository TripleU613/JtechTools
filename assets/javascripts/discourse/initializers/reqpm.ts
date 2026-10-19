import type Owner from "@ember/owner";
import getURL from "discourse/lib/get-url";
import { withPluginApi } from "discourse/lib/plugin-api";
import type BaseCommunitySectionLink from "discourse/lib/sidebar/base-community-section-link";
import { i18n } from "discourse-i18n";
import type { ReqpmCurrentUser, ReqpmSiteSettings } from "../services/reqpm.ts";

// Pages the setup prompt never covers: REQ-PM itself (the card editor is
// right there), admin (so an admin can always reach the settings), and the
// account/login flows.
const NO_PROMPT_ROUTES =
  /^(reqpm|admin|login|signup|password-reset|activate-account|email-login|invites)/;
const SESSION_KEY = "reqpm-setup-shown";

function promptedThisSession(): boolean {
  try {
    return window.sessionStorage.getItem(SESSION_KEY) === "1";
  } catch {
    return false;
  }
}

function markPrompted(): void {
  try {
    window.sessionStorage.setItem(SESSION_KEY, "1");
  } catch {
    // Private mode: the prompt may simply show once per page load.
  }
}

// REQ-PM entry points: an item in the avatar menu, a link in the sidebar's
// "More" list, the button on user cards/profiles and the preferences tab
// (connectors), and the "add your contact details" prompt.
export default {
  name: "jtech-reqpm",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as ReqpmSiteSettings;
    const currentUser = container.lookup(
      "service:current-user"
    ) as ReqpmCurrentUser | null;
    if (!siteSettings.reqpm_enabled || !currentUser?.reqpm?.available) {
      return;
    }
    const reqpm = container.lookup("service:reqpm");

    withPluginApi((api) => {
      // Kept out of the header on purpose: REQ-PM lives in the avatar menu,
      // the user's preferences, and the sidebar's "More" list.
      api.addQuickAccessProfileItem({
        icon: "address-card",
        href: getURL("/reqpm"),
        content: i18n("reqpm.menu.label"),
        className: "reqpm-menu-item",
      });

      api.addCommunitySectionLink(
        (BaseSectionLink: typeof BaseCommunitySectionLink) => {
          return class ReqpmSectionLink extends BaseSectionLink {
            get name() {
              return "reqpm";
            }

            get route() {
              return "reqpm";
            }

            get title() {
              return i18n("reqpm.sidebar.title");
            }

            get text() {
              return i18n("reqpm.sidebar.text");
            }

            get defaultPrefixValue() {
              return "address-card";
            }

            get badgeText() {
              return reqpm.incomingCount ? String(reqpm.incomingCount) : null;
            }
          };
        },
        true
      );

      const router = container.lookup("service:router");
      let open = false;
      api.onPageChange(() => {
        const mode = reqpm.setupPrompt;
        if (!mode || open) {
          return;
        }
        if (NO_PROMPT_ROUTES.test(router.currentRouteName || "")) {
          return;
        }
        // Gentle: once per browser session. Required: every page, until
        // something has been added.
        if (mode === "gentle" && promptedThisSession()) {
          return;
        }
        markPrompted();
        open = true;
        reqpm.openSetup(mode).finally(() => (open = false));
      });
    });
  },
};
