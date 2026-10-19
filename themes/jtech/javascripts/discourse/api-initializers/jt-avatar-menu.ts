import { apiInitializer } from "discourse/lib/api";
import type User from "discourse/models/user";
import type Header from "discourse/services/header";
import { pickUserMenuTab } from "../lib/jt-user-menu.ts";

type AvatarMenuUser = User & {
  can_review?: boolean;
  unseen_reviewable_count?: number;
};

// The header's bell opens core's user menu on notifications
// (components/jt-header-icon), and the avatar opened that very same tab, so
// the two did one thing. Opened from the avatar, the menu now starts on the
// profile tab (account, preferences, log out), or on the review queue when
// the avatar's badge says something is waiting there. The bell and the
// envelope open the menu with a scripted click (not isTrusted), so they keep
// their own tab.
export default apiInitializer((api) => {
  const user = api.getCurrentUser() as AvatarMenuUser | null;
  if (!user) {
    return;
  }
  const header = api.container.lookup("service:header") as Header;

  document.addEventListener(
    "click",
    (event) => {
      const target = event.target as Element | null;
      if (
        !event.isTrusted ||
        header.userVisible ||
        !target?.closest("#toggle-current-user")
      ) {
        return;
      }
      pickUserMenuTab(
        user.can_review && user.unseen_reviewable_count
          ? "review-queue"
          : "profile"
      );
    },
    // before core's own handler opens the menu, while it's still closed
    true
  );
});
