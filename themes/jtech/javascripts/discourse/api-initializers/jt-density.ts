import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import { applyDensity } from "../lib/jt-density";

// The density chosen in the palette menu, on <html> before the first list
// draws (lib/jt-density). With the menu off nobody can choose one, so lists
// keep the default.
export default apiInitializer(() => {
  if (settings.palette_menu) {
    applyDensity();
  }
});
