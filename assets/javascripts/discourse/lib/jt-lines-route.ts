import type RouterService from "@ember/routing/router-service";
import { defaultHomepage } from "discourse/lib/utilities";

// The welcome area's pages: the homepage, Latest and Categories, not inside
// a category or tag. The JTech theme's hero shows on the same ones.
export function onWelcomeRoute(
  router: RouterService,
  scoped: boolean
): boolean {
  if (scoped) {
    return false;
  }
  const routes = [
    `discovery.${defaultHomepage()}`,
    "discovery.latest",
    "discovery.categories",
  ];
  return routes.includes(router.currentRouteName ?? "");
}
