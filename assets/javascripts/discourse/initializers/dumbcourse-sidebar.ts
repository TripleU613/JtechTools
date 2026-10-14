import { apiInitializer } from "discourse/lib/api";
import getURL from "discourse/lib/get-url";
import type SiteSettingsService from "discourse/services/site-settings";
import { i18n } from "discourse-i18n";

interface SidebarSection {
  links?: { value?: string }[];
}

type DumbcourseSiteSettings = SiteSettingsService & {
  dumbcourse_enabled: boolean;
  dumbcourse_sidebar_link_enabled: boolean;
  dumbcourse_base_path: string;
};

export default apiInitializer((api) => {
  const siteSettings: DumbcourseSiteSettings | undefined = api.container.lookup(
    "service:site-settings"
  );
  if (!siteSettings?.dumbcourse_enabled) {
    return;
  }
  if (!siteSettings?.dumbcourse_sidebar_link_enabled) {
    return;
  }

  const basePath = (siteSettings?.dumbcourse_base_path || "dumb").replace(
    /^\/+|\/+$/g,
    ""
  );

  // An admin who put a Dumbcourse link in one of the sidebar's own sections
  // (Community, say) gets that one, not a second in a section of its own.
  const path = getURL(`/${basePath || "dumb"}`);
  const linkedElsewhere = (): boolean => {
    const user = api.getCurrentUser() as {
      sidebar_sections?: SidebarSection[];
    } | null;
    const site = api.container.lookup("service:site") as {
      anonymous_sidebar_sections?: SidebarSection[];
    };
    const sections = user
      ? user.sidebar_sections
      : site.anonymous_sidebar_sections;
    return (sections || []).some((section) =>
      (section.links || []).some(
        (link) => (link.value || "").replace(/\/+$/, "") === path
      )
    );
  };

  api.addSidebarSection(
    (BaseCustomSidebarSection, BaseCustomSidebarSectionLink) => {
      class DumbcourseLink extends BaseCustomSidebarSectionLink {
        name = "dumbcourse";
        classNames = "raw-link";
        text = i18n("dumbcourse.sidebar_link_text");
        title = i18n("dumbcourse.sidebar_link_title");
        href = path;
        prefixType = "icon";
        prefixValue = "mobile-screen-button";
      }

      return class DumbcourseSection extends BaseCustomSidebarSection {
        name = "dumbcourse";
        text = i18n("dumbcourse.sidebar_section_title");
        title = i18n("dumbcourse.sidebar_section_title");
        hideSectionHeader = true;

        get displaySection() {
          return !linkedElsewhere();
        }

        get links() {
          return [new DumbcourseLink()];
        }
      };
    }
  );
});
