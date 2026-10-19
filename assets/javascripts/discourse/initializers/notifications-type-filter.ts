import type Owner from "@ember/owner";
import { withPluginApi } from "discourse/lib/plugin-api";
import type SiteSettingsService from "discourse/services/site-settings";
import NotificationsTypeFilter from "../components/notifications-type-filter.gts";

// Adds a second filter dropdown to /u/{username}/notifications, sitting
// next to Discourse's existing All / Read / Unread filter. The dropdown
// sets ?type=<name>, the route picks it up as a queryParam, and the
// server's NotificationsController patch (sub_plugins/mod_categories.rb)
// scopes the result set accordingly. Staff-only `mod_notes` is gated on
// both sides — the dropdown hides it for non-staff and the controller
// drops the filter silently if a non-staff user passes it via the URL.
export default {
  name: "discourse-mod-notifications-type-filter",

  initialize(container: Owner) {
    const siteSettings = container.lookup(
      "service:site-settings"
    ) as SiteSettingsService & {
      mod_notification_type_filter_enabled: boolean;
    };
    if (!siteSettings.mod_notification_type_filter_enabled) {
      return;
    }

    withPluginApi((api) => {
      // Renders directly inside `<div class="user-notifications-filter">`,
      // right after Discourse's built-in NotificationsFilter — so the two
      // dropdowns naturally sit side-by-side without any float / position
      // gymnastics. Outlet confirmed against
      // discourse/discourse:frontend/discourse/app/templates/user/notifications-index.gjs.
      api.renderInOutlet(
        "user-notifications-after-filter",
        NotificationsTypeFilter
      );

      // The userNotifications.index route inherits both controllerName and
      // model() from its parent `user-notifications` route, so that's where
      // model() is actually defined — overriding the `.index` route does
      // nothing because it has no model() of its own. See discourse/
      // discourse: frontend/discourse/app/routes/user-notifications.js.
      //
      // We deliberately do NOT try to declare `type` as a controller
      // queryParam: Discourse's controller uses `queryParams = ["filter"]`,
      // a class FIELD, and Ember's classic reopen() (which api.modifyClass
      // uses under the hood) only patches prototype METHODS — it can't
      // override class-field initializers, so `type` would be silently
      // stripped from params before reaching model(). Instead we read
      // `type` directly from window.location.search inside model(); the
      // URL is the source of truth in either path (initial visit OR the
      // dropdown's history.pushState, which updates the location).
      //
      // Discourse's store typically forwards unknown arg keys onto the
      // GET URL as query params, but the previous implementation that
      // tried to thread `type` through `store.find("notification", { type })`
      // wasn't actually reaching the controller — passing it through
      // `filter_by_types` directly is the more reliable shape: that key
      // is what the core NotificationsController parses, no server-side
      // translation needed for ordinary types. The server patch still
      // exists for the staff-only `mod_notes` pseudo-type (the controller
      // patch redirects that branch to a custom scoped index) — that path
      // continues to go through `args.type`.
      api.modifyClass(
        "route:user-notifications",
        {
          pluginId: "discourse-mod-categories-notifications-filter",

          model(params: { filter?: string }) {
            const username = this.modelFor("user").get("username");
            if (
              this.get("currentUser.username") !== username &&
              !this.get("currentUser.admin")
            ) {
              return;
            }
            const args: {
              username: string;
              filter?: string;
              limit: number;
              type?: string;
            } = { username, filter: params.filter, limit: 60 };
            const urlType = new URLSearchParams(window.location.search).get(
              "type"
            );
            if (urlType && urlType !== "all") {
              // Pass the type as `?type=` rather than `?filter_by_types=` —
              // Discourse's core NotificationsController#index only honours
              // `filter_by_types` on the `?recent=true` path (the user-menu
              // dropdown). The standard /u/{username}/notifications page
              // falls into the `else` branch, which ignores type filters
              // entirely. The plugin's controller patch (sub_plugins/
              // mod_categories.rb) intercepts `?type=` for this exact
              // reason and renders a type-filtered index itself.
              args.type = urlType;
            }
            return this.store.find("notification", args);
          },
        },
        undefined
      );
    });
  },
};
