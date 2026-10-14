// The Discourse palettes are more than colours: picked, the forum takes stock
// Discourse's look as well (jt-vanilla.scss): its shades instead of the
// theme's flattened greys, colour where Discourse has it (categories, letter
// avatars, the timeline), solid borders, square-ish corners, a solid header,
// and Font Awesome icons instead of Lucide (api-initializers/jt-lucide-icons).
// It follows the palette on screen: the head's light or dark stylesheet,
// whichever the mode shows.

interface NamedScheme {
  id: number;
  name: string;
}

interface SchemeSite {
  user_color_schemes?: NamedScheme[] | null;
  default_light_color_scheme?: NamedScheme | null;
  default_dark_color_scheme?: NamedScheme | null;
}

const FAMILY = /^Discourse (Light|Dark)$/;
export const VANILLA_CLASS = "jt-vanilla";

export function showingDark(): boolean {
  const dark = document.querySelector<HTMLLinkElement>("link.dark-scheme");
  return !!dark && window.matchMedia(dark.media).matches;
}

export function shownSchemeId(): number {
  return Number(
    document.querySelector<HTMLLinkElement>(
      showingDark() ? "link.dark-scheme" : "link.light-scheme"
    )?.dataset.schemeId
  );
}

export function isVanillaScheme(site: SchemeSite, id: number): boolean {
  const schemes = [
    ...(site.user_color_schemes ?? []),
    site.default_light_color_scheme,
    site.default_dark_color_scheme,
  ];
  const name = schemes.find((s) => s?.id === id)?.name;
  return !!name && FAMILY.test(name);
}

export function vanillaShown(site: SchemeSite): boolean {
  return isVanillaScheme(site, shownSchemeId());
}

export function applyVanilla(site: SchemeSite): boolean {
  const on = vanillaShown(site);
  document.documentElement.classList.toggle(VANILLA_CLASS, on);
  return on;
}
