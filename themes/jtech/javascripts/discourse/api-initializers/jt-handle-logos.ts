import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import { HANDLE_LOGOS } from "../lib/jt-handle-logos.ts";

// A logo after a mention of one of lib/jt-handle-logos' handles (setting
// handle_logos), in posts and the composer's preview. Core cooks a mention
// of an account as a link to /u/<name> and of a name nobody has as a span;
// both get it, so it works whether or not the account exists. The link's
// path gives the name, since core can add a status emoji to its text.
function handleOf(mention: HTMLElement): string {
  const fromPath =
    mention instanceof HTMLAnchorElement
      ? /\/u\/([^/?#]+)/.exec(mention.pathname)?.[1]
      : undefined;
  const name = fromPath
    ? decodeURIComponent(fromPath)
    : (mention.textContent ?? "").trim().replace(/^@/, "");
  return name.toLowerCase();
}

export default apiInitializer((api) => {
  if (!settings.handle_logos) {
    return;
  }

  api.decorateCookedElement(
    (element: HTMLElement) => {
      for (const mention of element.querySelectorAll<HTMLElement>(".mention")) {
        const handle = handleOf(mention);
        if (
          !HANDLE_LOGOS.has(handle) ||
          mention.querySelector(".jt-handle-logo")
        ) {
          continue;
        }
        const logo = document.createElement("span");
        logo.className = "jt-handle-logo";
        logo.dataset.jtHandle = handle;
        logo.setAttribute("aria-hidden", "true");
        mention.append(logo);
        mention.classList.add("jt-handle");
      }
    },
    { id: "jt-handle-logos" }
  );
});
