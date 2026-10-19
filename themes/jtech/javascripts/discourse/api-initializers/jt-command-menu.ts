import { apiInitializer } from "discourse/lib/api";
import type ModalService from "discourse/services/modal";
import JtCommandMenu from "../components/jt-command-menu.gts";
import { commandMenuShortcutBound } from "../lib/jt-command-menu-shortcut.ts";

// ⌘K / Ctrl+K opens the command menu. Not global: inside the composer and
// other text fields Ctrl+K keeps meaning "insert link".
export default apiInitializer((api) => {
  if (!commandMenuShortcutBound(api.container)) {
    return;
  }

  const modal = api.container.lookup("service:modal") as ModalService;

  api.addKeyboardShortcut(
    "mod+k",
    (event?: KeyboardEvent) => {
      event?.preventDefault();
      // Don't swap out a dialog someone is in the middle of (flagging, …).
      if (modal.activeModal) {
        return;
      }
      modal.show(JtCommandMenu, undefined);
    },
    { anonymous: true }
  );
});
