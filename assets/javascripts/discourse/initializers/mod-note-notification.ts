import { withPluginApi } from "discourse/lib/plugin-api";
import modNoteNotificationRenderer from "../lib/mod-note-notification.ts";

// Registers the moderator-note notification renderer. The plugin's
// moderator-note notifications use the `custom` notification type; the
// renderer distinguishes them from other custom notifications via the
// `mod_note` marker in the notification `data` and defers to the base
// class for everything else.
export default {
  name: "discourse-mod-note-notification",

  initialize() {
    withPluginApi((api) => {
      // Core types the renderer callback as instance -> instance; it really
      // receives and returns the class.
      api.registerNotificationTypeRenderer(
        "custom",
        modNoteNotificationRenderer as unknown as Parameters<
          typeof api.registerNotificationTypeRenderer
        >[1]
      );
    });
  },
};
