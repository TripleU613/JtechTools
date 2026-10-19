import { apiInitializer } from "discourse/lib/api";
import type Site from "discourse/models/site";
import {
  alignPalettePreviews,
  type JtPaletteInfo,
} from "../lib/jt-color-mode.ts";

// Core fires interface-color:changed from every light/dark switch (its
// sidebar menu, its header selector, preferences, the theme's own), after
// flipping the head's palette links; a palette preview left over from
// Preferences → Interface follows them (lib/jt-color-mode). Not tied to the
// theme's switch settings: core's menu needs it too.
export default apiInitializer((api) => {
  const site = api.container.lookup("service:site") as Site & {
    user_color_schemes?: JtPaletteInfo[] | null;
  };
  api.onAppEvent("interface-color:changed", () =>
    alignPalettePreviews(site.user_color_schemes)
  );
});
