import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";

// Code blocks whose author named a language (```bash) get a header showing it.
// Auto-detected blocks stay bare: highlight.js guesses (smali reads as
// "ruby"), and a wrong label is worse than none.
const SKIP = new Set(["auto", "nohighlight", "plaintext", "text", "txt"]);
const ALIASES: Record<string, string> = {
  js: "javascript",
  md: "markdown",
  ps1: "powershell",
  py: "python",
  sh: "shell",
  ts: "typescript",
  yml: "yaml",
};

// Line numbers sit in their own gutter beside the <code>, never inside it:
// highlight.js rewrites the code's markup, copy buttons read its text, and
// neither should see the numbers.
function addLineNumbers(pre: HTMLElement, code: HTMLElement): void {
  if (pre.querySelector(":scope > .jt-code-gutter") || pre.closest("aside")) {
    return;
  }
  const lines = (code.textContent ?? "").replace(/\n$/, "").split("\n").length;
  if (lines < 2) {
    return;
  }
  const gutter = document.createElement("span");
  gutter.className = "jt-code-gutter";
  gutter.setAttribute("aria-hidden", "true");
  gutter.textContent = Array.from({ length: lines }, (_, i) => i + 1).join(
    "\n"
  );
  pre.classList.add("jt-numbered");
  pre.insertBefore(gutter, code);
  // core scrolls a tall <code> inside its box: the numbers follow, and stop
  // above its horizontal scrollbar, as the lines do
  code.addEventListener("scroll", () => (gutter.scrollTop = code.scrollTop), {
    passive: true,
  });
  new ResizeObserver(() => {
    const box = getComputedStyle(code);
    const bar =
      code.offsetHeight -
      code.clientHeight -
      parseFloat(box.borderTopWidth) -
      parseFloat(box.borderBottomWidth);
    gutter.style.setProperty("--jt-hbar", `${bar}px`);
  }).observe(code);
}

export default apiInitializer((api) => {
  if (!settings.code_language_labels && !settings.code_line_numbers) {
    return;
  }

  api.decorateCookedElement(
    (element: HTMLElement) => {
      for (const code of element.querySelectorAll<HTMLElement>(
        "pre:not(.onebox) > code"
      )) {
        const pre = code.parentElement as HTMLElement;
        const lang = code.className.match(/(?:^|\s)lang-([\w+#.-]+)/)?.[1];
        if (
          settings.code_language_labels &&
          lang &&
          !SKIP.has(lang.toLowerCase())
        ) {
          pre.dataset.jtLang =
            ALIASES[lang.toLowerCase()] || lang.toLowerCase();
        }
        if (settings.code_line_numbers && lang !== "mermaid") {
          addLineNumbers(pre, code);
        }
      }
    },
    { id: "jt-code-blocks" }
  );
});
