import type RouterService from "@ember/routing/router-service";
import { apiInitializer } from "discourse/lib/api";
import { needsFullPageLoad } from "../lib/jt-links.ts";

// Links inside posts to same-site pages that aren't forum pages (the landing
// site at /home, /terms, …) open as a normal page load instead of the forum's
// 404 page. Same rule as the header, hero and footer (lib/jt-links.ts).
export default apiInitializer((api) => {
  const router = api.container.lookup("service:router") as RouterService;

  api.decorateCookedElement(
    (element: HTMLElement) => {
      for (const link of element.querySelectorAll<HTMLAnchorElement>(
        "a[href]"
      )) {
        if (!link.dataset.autoRoute && needsFullPageLoad(router, link.href)) {
          link.dataset.autoRoute = "true";
        }
      }
    },
    { id: "jt-post-links" }
  );
});
