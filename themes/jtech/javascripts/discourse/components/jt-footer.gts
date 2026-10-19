import Component from "@glimmer/component";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import {
  type JtechThemeFooterLink,
  settings,
  themePrefix,
} from "virtual:theme";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import { needsFullPageLoad } from "../lib/jt-links.ts";
import JtechMark from "./jtech-mark.gts";

interface FooterColumnLink extends JtechThemeFooterLink {
  fullPage: boolean;
}

interface FooterColumn {
  title: string;
  links: FooterColumnLink[];
}

interface JtFooterSignature {
  Args: Record<string, never>;
}

interface FooterUser {
  username: string;
}

interface FooterSiteSettings {
  allow_new_registrations: boolean;
}

// Site footer: mark + tagline, link columns grouped by `section` (in the order
// sections first appear in the footer_links setting), an Account column of
// its own (logging in and signing up, or the member's profile, messages,
// bookmarks and preferences) before Legal, and small print with a way back
// to the top.
export default class JtFooter extends Component<JtFooterSignature> {
  @service declare router: RouterService;
  @service declare currentUser: FooterUser | null;
  @service declare siteSettings: FooterSiteSettings;

  get columns(): FooterColumn[] {
    const bySection = new Map<string, FooterColumnLink[]>();
    for (const link of settings.footer_links || []) {
      if (!bySection.has(link.section)) {
        bySection.set(link.section, []);
      }
      bySection.get(link.section).push({
        ...link,
        fullPage: needsFullPageLoad(this.router, link.url),
      });
    }
    const columns = [...bySection].map(([title, links]) => ({ title, links }));
    const legal = columns.findIndex((c) => /^legal$/i.test(c.title));
    columns.splice(legal === -1 ? columns.length : legal, 0, this.account);
    return columns;
  }

  get account(): FooterColumn {
    const t = (key: string) => i18n(themePrefix(`jt.footer.${key}`));
    const link = (title: string, url: string): FooterColumnLink => ({
      section: "",
      title,
      url: getURL(url),
      fullPage: false,
    });
    const user = this.currentUser;
    if (!user) {
      return {
        title: t("account"),
        links: [
          link(t("log_in"), "/login"),
          ...(this.siteSettings.allow_new_registrations
            ? [link(t("sign_up"), "/signup")]
            : []),
        ],
      };
    }
    const me = `/u/${encodeURIComponent(user.username)}`;
    return {
      title: t("account"),
      links: [
        link(t("profile"), `${me}/summary`),
        link(t("messages"), `${me}/messages`),
        link(t("bookmarks"), `${me}/activity/bookmarks`),
        link(t("preferences"), `${me}/preferences`),
      ],
    };
  }

  get termsUrl(): string {
    return getURL("/tos");
  }

  get year(): number {
    return new Date().getFullYear();
  }

  @action
  toTop(event: Event) {
    event.preventDefault();
    window.scrollTo({ top: 0, behavior: "smooth" });
  }

  <template>
    <footer class="jt-footer">
      <div class="jt-footer__inner">
        <div class="jt-footer__brand">
          <span class="jt-footer__mark"><JtechMark /></span>
          <span class="jt-footer__name">JTech Forums</span>
          {{#if settings.footer_tagline}}
            <p
              class="jt-footer__tagline"
              dir="auto"
            >{{settings.footer_tagline}}</p>
          {{/if}}
        </div>

        <nav
          aria-label={{i18n (themePrefix "jt.footer.label")}}
          class="jt-footer__columns"
        >
          {{#each this.columns as |column|}}
            <div class="jt-footer__column">
              <h2 class="jt-footer__heading">{{column.title}}</h2>
              <ul>
                {{#each column.links as |link|}}
                  <li><a
                      data-auto-route={{if link.fullPage "true"}}
                      href={{link.url}}
                    >{{link.title}}</a></li>
                {{/each}}
              </ul>
            </div>
          {{/each}}
        </nav>
      </div>

      <div class="jt-footer__base">
        <span>© {{this.year}} JTech Forums</span>
        {{#if settings.footer_notice}}
          <p class="jt-footer__notice" dir="auto">
            {{settings.footer_notice}}
            <a href={{this.termsUrl}}>{{i18n
                (themePrefix "jt.footer.terms")
              }}</a>
          </p>
        {{/if}}
        <a class="jt-footer__top" href="#" {{on "click" this.toTop}}>
          {{i18n (themePrefix "jt.footer.back_to_top")}}
          ↑
        </a>
      </div>
    </footer>
  </template>
}
