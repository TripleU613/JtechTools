import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { type TrustedHTML, trustHTML } from "@ember/template";
import DMenu from "float-kit/components/d-menu";
import { settings, themePrefix } from "virtual:theme";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { updateColorSchemeCookie } from "discourse/lib/color-scheme-picker";
import { currentThemeId } from "discourse/lib/theme-selector";
import type Site from "discourse/models/site";
import type User from "discourse/models/user";
import type InterfaceColor from "discourse/services/interface-color";
import dIcon from "discourse/ui-kit/helpers/d-icon";
import { i18n } from "discourse-i18n";
import { showingDark, vanillaShown } from "../../lib/jt-vanilla";

interface Scheme {
  id: number;
  name: string;
  is_dark: boolean;
  theme_id?: number;
  colors?: { name: string; hex: string }[];
}

interface SiteTheme {
  theme_id: number;
  color_scheme_id: number | null;
  dark_color_scheme_id: number | null;
}

type PaletteSite = Site & {
  user_color_schemes?: Scheme[] | null;
  user_themes?: SiteTheme[] | null;
};

type PaletteUser = User & { username: string; jtech_icon_style?: string };

// A palette pair: "Ocean Light" and "Ocean Dark" are one row. A palette
// without a partner takes the theme's default for the other mode.
interface Family {
  name: string;
  light: Scheme;
  dark: Scheme;
  ownMode?: "light" | "dark";
  active: boolean;
  swatch: TrustedHTML;
}

const HEX = /^[0-9a-f]{3,8}$/i;

function color(scheme: Scheme, name: string): string {
  const hex = scheme.colors?.find((c) => c.name === name)?.hex ?? "";
  return HEX.test(hex) ? `#${hex}` : "transparent";
}

// Puts a palette's stylesheet in place of the head's light or dark one. The
// new link loads before the old goes, so the page never shows unstyled. Core's
// light/dark switch flips these same links, so it keeps working.
async function swapStylesheet(scheme: Scheme, dark: boolean, themeId: number) {
  const current = document.querySelector<HTMLLinkElement>(
    dark ? "link.dark-scheme" : "link.light-scheme"
  );
  if (!current || current.dataset.schemeId === String(scheme.id)) {
    return;
  }
  const { new_href } = (await ajax(
    `/color-scheme-stylesheet/${scheme.id}/${themeId}.json`
  )) as { new_href?: string };
  if (!new_href) {
    return;
  }
  const next = current.cloneNode() as HTMLLinkElement;
  next.href = new_href;
  next.dataset.schemeId = String(scheme.id);
  await new Promise((resolve) => {
    next.onload = next.onerror = resolve;
    current.after(next);
  });
  current.remove();

  // A phone's browser tints its bar with theme-color, one tag per mode
  // (light first) while the theme has a dark palette
  const tints = document.querySelectorAll<HTMLMetaElement>(
    'meta[name="theme-color"]'
  );
  const tint = tints.length > 1 ? tints[dark ? 1 : 0] : dark ? null : tints[0];
  tint?.setAttribute("content", color(scheme, "header_background"));
}

// The sidebar footer's palette button: every palette the theme offers, one
// click to switch, no reload. A member's choice is saved to their account
// (like Preferences → Interface with "all devices"); a visitor's to cookies.
export default class JtPaletteMenu extends Component {
  @service declare site: PaletteSite;
  @service declare currentUser: PaletteUser | null;
  @service declare interfaceColor: InterfaceColor;

  // Read when the menu opens: what's on screen changes without telling us
  // (core's light/dark switch, the device's own mode).
  @tracked families: Family[] = [];

  get theme(): SiteTheme | undefined {
    const id = currentThemeId() as number;
    return this.site.user_themes?.find((t) => t.theme_id === id);
  }

  get available(): boolean {
    return settings.palette_menu && this.readFamilies().length > 1;
  }

  get iconsFollowPalette(): boolean {
    return (
      settings.lucide_icons && this.currentUser?.jtech_icon_style !== "classic"
    );
  }

  readFamilies(): Family[] {
    const theme = this.theme;
    const schemes = (this.site.user_color_schemes ?? [])
      .filter((s) => s.theme_id === theme?.theme_id)
      .sort((a, b) => a.id - b.id);
    const defaultLight = schemes.find((s) => s.id === theme?.color_scheme_id);
    const defaultDark = schemes.find(
      (s) => s.id === theme?.dark_color_scheme_id
    );
    if (!defaultLight || !defaultDark) {
      return [];
    }

    const grouped = new Map<string, { light?: Scheme; dark?: Scheme }>();
    for (const scheme of schemes) {
      const name = scheme.name.replace(/\s+(Light|Dark)$/, "");
      const family = grouped.get(name) ?? {};
      family[scheme.is_dark ? "dark" : "light"] = scheme;
      grouped.set(name, family);
    }

    const dark = showingDark();
    const shownId = Number(
      document.querySelector<HTMLLinkElement>(
        dark ? "link.dark-scheme" : "link.light-scheme"
      )?.dataset.schemeId
    );
    return [...grouped].map(([name, own]) => {
      const light = own.light ?? defaultLight;
      const darkScheme = own.dark ?? defaultDark;
      const shown = dark ? darkScheme : light;
      const ownMode = !own.light ? "dark" : !own.dark ? "light" : undefined;
      return {
        name,
        light,
        dark: darkScheme,
        ownMode,
        active: ownMode
          ? (own.light ?? own.dark)?.id === shownId
          : shown.id === shownId,
        swatch: trustHTML(
          `--jt-swatch-paper: ${color(shown, "secondary")}; --jt-swatch-ink: ${color(shown, "tertiary")}`
        ),
      };
    });
  }

  @action
  refresh() {
    this.families = this.readFamilies();
  }

  @action
  async choose(family: Family, close: () => void) {
    void close();
    const themeId = currentThemeId() as number;
    const wasVanilla = vanillaShown(this.site);
    try {
      await Promise.all([
        swapStylesheet(family.light, false, themeId),
        swapStylesheet(family.dark, true, themeId),
      ]);
      if (family.ownMode === "dark") {
        this.interfaceColor.forceDarkMode();
      } else if (family.ownMode === "light") {
        this.interfaceColor.forceLightMode();
      }
      await this.remember(family);
      // Into or out of a Discourse palette the icons change too (Font
      // Awesome there, Lucide elsewhere), and those are set as the page loads
      if (vanillaShown(this.site) !== wasVanilla && this.iconsFollowPalette) {
        window.location.reload();
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  // The theme's own defaults are saved as "the theme's default" (-1 / no
  // cookie), as Preferences → Interface does, so they follow the theme if an
  // admin changes its palettes.
  async remember(family: Family) {
    const theme = this.theme;
    const light =
      family.light.id === theme?.color_scheme_id ? null : family.light.id;
    const dark =
      family.dark.id === theme?.dark_color_scheme_id ? null : family.dark.id;

    if (!this.currentUser) {
      updateColorSchemeCookie(light);
      updateColorSchemeCookie(dark, { dark: true });
      return;
    }
    await ajax(`/u/${this.currentUser.username}.json`, {
      type: "PUT",
      data: { color_scheme_id: light ?? -1, dark_scheme_id: dark ?? -1 },
    });
    // A device-only choice from Preferences would otherwise win over this one
    updateColorSchemeCookie(null);
    updateColorSchemeCookie(null, { dark: true });
  }

  <template>
    {{#if this.available}}
      <DMenu
        class="jt-palette-menu icon"
        @ariaLabel={{i18n (themePrefix "jt.palettes.title")}}
        @icon="palette"
        @identifier="jt-palette-menu"
        @onShow={{this.refresh}}
        @title={{i18n (themePrefix "jt.palettes.title")}}
        @triggerClass="btn-flat sidebar-footer-actions-button"
      >
        <:content as |menu|>
          <ul class="jt-palettes" role="menu">
            {{#each this.families as |family|}}
              <li role="none">
                <button
                  aria-checked={{if family.active "true" "false"}}
                  class="btn btn-transparent jt-palettes__option
                    {{if family.active '--active'}}"
                  role="menuitemradio"
                  type="button"
                  {{on "click" (fn this.choose family menu.close)}}
                >
                  <span
                    class="jt-palettes__swatch"
                    style={{family.swatch}}
                  ></span>
                  <span class="jt-palettes__name">{{family.name}}</span>
                  {{#if family.active}}{{dIcon "check"}}{{/if}}
                </button>
              </li>
            {{/each}}
          </ul>
        </:content>
      </DMenu>
    {{/if}}
  </template>
}
