import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import { applyDensity } from "../lib/jt-density.ts";

// The density chosen in the sidebar's density menu, on <html> before the
// first list draws (lib/jt-density). With the menu off nobody can choose one,
// so lists keep the default.
export default apiInitializer(() => {
  if (settings.density_menu) {
    applyDensity();
  }
});
