import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";

interface LinesHost {
  hostInTheme(): void;
}

// With jtech-tools' ads on (docs/features/ads.md), the hero carries the
// welcome area's line itself, so the plugin's plain card stays out. Said at
// startup, before anything renders. Without the plugin there's no service
// and nothing to say.
export default apiInitializer((api) => {
  if (!settings.hero_enabled) {
    return;
  }
  const lines = api.container.lookup("service:jt-lines") as
    | LinesHost
    | undefined;
  lines?.hostInTheme();
});
