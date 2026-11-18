import type { DSL } from "@ember/routing/lib/dsl";

// Child routes for the /admin/plugins/jtech-tools config page — one per
// sub-plugin tab. Must live in the MAIN bundle: the Ember router collects
// every `*-route-map` module once at boot, and the admin bundle is a
// staff-gated dynamic import that loads too late.
//
// Route names become adminPlugins.show.jtech-tools-*; URLs
// /admin/plugins/jtech-tools/<path>. "settings" is reserved (core's own
// all-settings child route) — never name a child route that.
export default {
  resource: "admin.adminPlugins.show",
  map(this: DSL) {
    this.route("jtech-tools-dislike", { path: "dislike" });
    this.route("jtech-tools-smtp", { path: "smtp" });
    this.route("jtech-tools-mini-mod", { path: "mini-mod" });
    this.route("jtech-tools-mod", { path: "mod" });
    this.route("jtech-tools-dumbcourse", { path: "dumbcourse" });
    this.route("jtech-tools-translator", { path: "translator" });
    this.route("jtech-tools-smart-search", { path: "smart-search" });
    this.route("jtech-tools-popups", { path: "popups" });
    this.route("jtech-tools-disteleplus", { path: "disteleplus" });
    this.route("jtech-tools-reqpm", { path: "reqpm" });
    this.route("jtech-tools-listing-format", { path: "listing-format" });
    this.route("jtech-tools-mod-elections", { path: "mod-elections" });
    this.route("jtech-tools-market-accounts", { path: "market-accounts" });
  },
};
