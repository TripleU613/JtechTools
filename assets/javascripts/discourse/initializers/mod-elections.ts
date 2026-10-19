import type Owner from "@ember/owner";
import escape from "discourse/lib/escape";
import { longDate } from "discourse/lib/formatter";
import getURL from "discourse/lib/get-url";
import { iconHTML } from "discourse/lib/icon-library";
import { withPluginApi } from "discourse/lib/plugin-api";
import type BaseCommunitySectionLink from "discourse/lib/sidebar/base-community-section-link";
import { i18n } from "discourse-i18n";
import type {
  ModElectionsCurrentUser,
  ModElectionsSiteSettings,
  ModElectionSummary,
} from "../services/mod-elections.ts";

// Whether the banner is for this person: during nominations everyone signed
// in sees it; during Vote Week only voters who haven't voted. Nominations
// kept open for want of candidates have a banner of their own, so it comes
// back for those who dismissed the first.
function noticeFor(summary: ModElectionSummary | undefined): string | null {
  if (summary?.status === "nominating") {
    return summary.extended ? "nominating_extended" : "nominating";
  }
  if (summary?.status === "voting" && summary.voter && !summary.voted) {
    return "voting";
  }
  return null;
}

// The elections page in the sidebar's "More" list, with a dot while you
// have a vote to cast, and a banner across the top for each step.
export default {
  name: "jtech-mod-elections",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as ModElectionsSiteSettings;
    // The master switch (jtech_enabled) turns every module off.
    if (!siteSettings.jtech_enabled || !siteSettings.mod_elections_enabled) {
      return;
    }
    const currentUser = container.lookup(
      "service:current-user"
    ) as ModElectionsCurrentUser | null;
    // The page is for members in mod_elections_view_allowed_groups: nobody
    // else gets the link or the banner (the server turns them away too).
    if (!currentUser?.can_view_mod_elections) {
      return;
    }
    const summary = currentUser.mod_election;

    withPluginApi((api) => {
      api.addCommunitySectionLink(
        (BaseSectionLink: typeof BaseCommunitySectionLink) => {
          return class ModElectionsSectionLink extends BaseSectionLink {
            get name() {
              return "mod-elections";
            }

            get route() {
              return "mod-elections";
            }

            get title() {
              return i18n("mod_elections.sidebar.title");
            }

            get text() {
              return i18n("mod_elections.sidebar.text");
            }

            get defaultPrefixValue() {
              return "check-to-slot";
            }

            get badgeText() {
              return noticeFor(summary) === "voting" ? "1" : null;
            }
          };
        },
        true
      );

      const kind = noticeFor(summary);
      if (!kind || !summary) {
        return;
      }
      // Core puts the text in as HTML, so everything in it is escaped here.
      const text = (key: string, options = {}) =>
        escape(i18n(`mod_elections.notice.${key}`, options));
      const detail = summary.ends_at
        ? `<span class="mod-elections-notice__detail">${text(`${kind}_detail`, { date: longDate(summary.ends_at) })}</span>`
        : "";
      // The id stays as it was, so a banner someone closed stays closed.
      api.addGlobalNotice(
        `<span class="mod-elections-notice">` +
          `<span class="mod-elections-notice__icon" aria-hidden="true">${iconHTML("check-to-slot")}</span>` +
          `<span class="mod-elections-notice__body">` +
          `<span class="mod-elections-notice__label">${text("label")}</span>` +
          `<span class="mod-elections-notice__title">${text(`${kind}_title`)}</span>` +
          detail +
          `</span>` +
          `<a class="btn btn-primary mod-elections-notice__link" href="${getURL("/elections")}">${text(`${kind}_link`)}</a>` +
          `</span>`,
        `mod-elections-${summary.id}-${kind}`,
        { dismissable: true, persistentDismiss: true }
      );
    });
  },
};
