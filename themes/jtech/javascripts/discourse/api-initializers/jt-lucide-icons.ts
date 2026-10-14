import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import { REPLACEMENTS } from "discourse/lib/icon-library";
import { JT_ICON_MAP, jtIconId } from "../lib/jt-icon-map";
import { vanillaShown } from "../lib/jt-vanilla";

// Discourse's icons in Lucide's thin outline style (setting lucide_icons):
// each Font Awesome icon listed in lib/jt-icon-map points at the theme's
// sprite (assets/icons-sprite.svg) instead. Core's own aliases (d-liked →
// heart, notification.replied → reply, …) are only looked up one level deep,
// so they're pointed at the sprite as well. Unlisted icons stay Font Awesome.
// Someone who picked Classic icons (Preferences → Interface) keeps Font
// Awesome throughout, and so does a Discourse palette (lib/jt-vanilla), which
// looks like stock Discourse.
export default apiInitializer((api) => {
  if (!settings.lucide_icons) {
    return;
  }
  const user = api.getCurrentUser() as { jtech_icon_style?: string } | null;
  if (user?.jtech_icon_style === "classic") {
    return;
  }
  if (
    vanillaShown(
      api.container.lookup("service:site") as Parameters<typeof vanillaShown>[0]
    )
  ) {
    return;
  }
  // core's aliases, before this adds its own entries to the same table
  const aliases = Object.entries(REPLACEMENTS as Record<string, string>);

  for (const faIcon of Object.keys(JT_ICON_MAP)) {
    api.replaceIcon(faIcon, jtIconId(faIcon));
  }
  for (const [alias, faIcon] of aliases) {
    const id = jtIconId(faIcon);
    if (id) {
      api.replaceIcon(alias, id);
    }
  }
});
