// Dumbcourse: a light, D-pad friendly Discourse client for flip phones and
// old browsers. This file boots the app and lists its screens.

import { installPolyfills } from "./compat.ts";

installPolyfills();

import { mountShell } from "./app.ts";
import { adoptLegacyDrafts } from "./drafts.ts";
import { startBus, subscribe } from "./messagebus.ts";
import {
  applyPrefs,
  forgetLegacyKeys,
  prefs,
  watchSystemTheme,
} from "./prefs.ts";
import { registerPush } from "./push.ts";
import { notFound, route, start } from "./router.ts";
import { refreshUser, updateCounts, user } from "./session.ts";
import { getRaw } from "./storage.ts";
import { useScreen } from "./views/common.ts";
import {
  activateRoute,
  emailCodeRoute,
  emailLinkRoute,
  emailLoginTokenRoute,
  forgotRoute,
  fullSiteRoute,
  linkRoute,
  loginRoute,
  logoutRoute,
  pairRoute,
  resetTokenRoute,
  signupRoute,
} from "./views/auth.ts";
import { categoriesRoute } from "./views/categories.ts";
import { helpRoute } from "./views/help.ts";
import { bookmarksRoute, draftsRoute, messagesRoute } from "./views/lists.ts";
import { notificationsRoute } from "./views/notifications.ts";
import { phoneKeysRoute } from "./views/phone-keys.ts";
import {
  emailPrefsRoute,
  preferencesRoute,
  profilePrefsRoute,
} from "./views/preferences.ts";
import { profileRoute } from "./views/profile.ts";
import { electionsRoute } from "./views/elections.ts";
import { contactsRoute, contactUserRoute } from "./views/reqpm.ts";
import { reviewRoute } from "./views/review.ts";
import { searchRoute } from "./views/search.ts";
import { topicRoute } from "./views/topic.ts";
import {
  categoryRoute,
  homeRoute,
  listRoute,
  tagRoute,
} from "./views/topics.ts";

// ── Screens ───────────────────────────────────────────────────────────

route("/", homeRoute);
route("/latest", listRoute("latest"));
route("/new", listRoute("new"));
route("/unread", listRoute("unread"));
route("/unseen", listRoute("unread"));
route("/top", listRoute("top"));
route("/hot", listRoute("hot"));
route("/categories", categoriesRoute);
route("/c/*", categoryRoute);
route("/tag/*", tagRoute);
route("/t/*", topicRoute);
route("/messages", messagesRoute);
route("/notifications", notificationsRoute);
route("/bookmarks", bookmarksRoute);
route("/drafts", draftsRoute);
route("/search", searchRoute);
route("/review", reviewRoute);
route("/u/:username", profileRoute);
route("/contacts", contactsRoute);
route("/contacts/u/:username", contactUserRoute);
route("/elections", electionsRoute);
route("/preferences", preferencesRoute, { public: true });
route("/preferences/profile", profilePrefsRoute);
route("/preferences/email", emailPrefsRoute);
route("/help", helpRoute, { public: true });
route("/phone-keys", phoneKeysRoute, { public: true });
route("/link", linkRoute);
route("/logout", logoutRoute, { public: true });
route("/full-site", fullSiteRoute, { public: true });

route("/login", loginRoute, { public: true });
route("/login/email", emailLinkRoute, { public: true });
route("/login/code", emailCodeRoute, { public: true });
route("/login/device", pairRoute, { public: true });
route("/signup", signupRoute, { public: true });
route("/password-reset", forgotRoute, { public: true });
route("/password-reset/:token", resetTokenRoute, { public: true });
route("/email-login/:token", emailLoginTokenRoute, { public: true });
route("/activate-account/:token", activateRoute, { public: true });

// Old app paths.
route("/new-topic", homeRoute);
route("/settings", preferencesRoute, { public: true });
route("/register", signupRoute, { public: true });
route("/my", listRoute("latest"));

notFound(() => {
  const s = useScreen();
  s.title("Not found");
  s.error("There's no page here. Press 4 or Back to go back.");
});

// ── Boot ──────────────────────────────────────────────────────────────

function boot(): void {
  if (user)
    adoptLegacyDrafts(user.id, getRaw("jt_user_id"), getRaw("jt_drafts"));
  forgetLegacyKeys();
  applyPrefs();
  watchSystemTheme();
  mountShell();

  // Old share links used #/path.
  if (location.hash && location.hash.indexOf("#/") === 0) {
    try {
      history.replaceState(
        null,
        "",
        location.pathname.replace(/\/$/, "") + location.hash.slice(1)
      );
    } catch {
      // ignore
    }
  }

  start();

  if (user) {
    // Live counters for the bell and the menu.
    subscribe(`/notification/${user.id}`, (data) =>
      updateCounts(data as Record<string, number>)
    );
    if (user.reqpm_available) {
      subscribe("/reqpm/state", (data) => {
        const d = data as { incoming_count?: number };
        if (typeof d.incoming_count === "number")
          updateCounts({ reqpm_incoming_count: d.incoming_count });
      });
    }
    if (prefs.live) startBus();
    // Native wrapper app only: keep this device registered for pushes.
    registerPush();
    // Counters when coming back to the app after a while: not on every
    // quick switch away and back.
    let refreshedAt = Date.now();
    document.addEventListener("visibilitychange", () => {
      if (document.hidden || Date.now() - refreshedAt < 60000) return;
      refreshedAt = Date.now();
      void refreshUser();
    });
  }
}

if (document.readyState === "loading")
  document.addEventListener("DOMContentLoaded", boot);
else boot();
