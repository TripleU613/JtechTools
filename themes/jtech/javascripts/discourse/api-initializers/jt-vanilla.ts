import { apiInitializer } from "discourse/lib/api";
import { applyVanilla } from "../lib/jt-vanilla";

// html.jt-vanilla while a Discourse palette is on screen (lib/jt-vanilla).
// Set before the first render, then kept in step: core's light / dark switch
// flips the head's palette links (their media), the palette menu swaps them,
// and the device's own mode decides which one shows.
export default apiInitializer((api) => {
  const site = api.container.lookup("service:site") as Parameters<
    typeof applyVanilla
  >[0];
  const update = () => applyVanilla(site);
  update();

  new MutationObserver(update).observe(document.head, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["media", "data-scheme-id"],
  });
  window
    .matchMedia("(prefers-color-scheme: dark)")
    .addEventListener("change", update);
});
