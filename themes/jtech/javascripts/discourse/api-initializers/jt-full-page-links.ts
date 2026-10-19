import type RouterService from "@ember/routing/router-service";
import { apiInitializer } from "discourse/lib/api";
import { needsFullPageLoad } from "../lib/jt-links.ts";

// Same-site links that aren't forum pages (/home, /dumb, …) wherever core
// renders them, the sidebar's custom links and menus included: marked for a
// real page load as the click starts, before core's click interceptor (on the
// app's root, while the click bubbles) would route them to the forum's 404
// page. The header, footer and posts mark their links when they render.
export default apiInitializer((api) => {
  const router = api.container.lookup("service:router") as RouterService;
  document.addEventListener(
    "click",
    (event) => {
      const link = (event.target as Element | null)?.closest?.("a[href]");
      if (
        link instanceof HTMLAnchorElement &&
        !link.dataset.autoRoute &&
        needsFullPageLoad(router, link.getAttribute("href"))
      ) {
        link.dataset.autoRoute = "true";
      }
    },
    { capture: true }
  );
});
