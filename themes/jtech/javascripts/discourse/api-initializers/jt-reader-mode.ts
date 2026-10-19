import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import { readerMode } from "../lib/jt-reader.ts";

// Reader mode's keyboard shortcut, the component's Ctrl+Alt+R. The
// switch itself is connectors/timeline-controls-before/jt-reader-mode.
export default apiInitializer((api) => {
  if (!settings.reader_mode) {
    return;
  }
  readerMode.apply();
  api.addKeyboardShortcut("ctrl+alt+r", () => readerMode.toggle(), {
    global: true,
  });
});
