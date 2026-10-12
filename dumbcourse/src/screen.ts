// The current screen. Each route render gets a Screen: it owns the title,
// the content area, the soft keys, keypad shortcuts and click actions for
// as long as it is showing, and everything it registered is dropped when
// the next screen takes over. Async views check `alive` after each await
// so a slow response never paints over the screen you moved on to.

import { closest } from "./compat.ts";
import { byId, setHtml } from "./dom.ts";
import { html, type SafeHtml } from "./html.ts";
import type { Key } from "./keys.ts";
import { focusByKey } from "./nav.ts";
import { icon } from "./ui/icons.ts";
import { setPageSoftkeys } from "./ui/softkeys.ts";

export type ActionHandler = (el: HTMLElement, e: Event) => void;

export interface SoftAction {
  label: string;
  run: () => void;
}

export interface Screen {
  readonly id: number;
  alive(): boolean;
  title(text: string, opts?: { back?: boolean; sub?: string }): void;
  render(markup: SafeHtml): void;
  content(): HTMLElement;
  onLeave(fn: () => void): void;
  keys(map: Partial<Record<Key, () => void>>): void;
  act(name: string, fn: ActionHandler): void;
  softkeys(opts: {
    left?: SoftAction | null;
    center?: string;
    right?: SoftAction | null;
  }): void;
  loading(message?: string): void;
  error(message: string, retry?: () => void): void;
  empty(message: SafeHtml | string, iconName?: string): void;
  // Shows or hides the top-bar "new" button.
  compose(target: string | null, label?: string): void;
}

let counter = 0;
let active: ScreenImpl | null = null;
let titleHook: ((text: string, back: boolean, sub: string) => void) | null =
  null;
let composeHook: ((target: string | null, label: string) => void) | null = null;

export function setTitleHook(
  fn: (text: string, back: boolean, sub: string) => void
): void {
  titleHook = fn;
}

export function setComposeHook(
  fn: (target: string | null, label: string) => void
): void {
  composeHook = fn;
}

class ScreenImpl implements Screen {
  readonly id: number;
  leaves: Array<() => void> = [];
  keyMap: Partial<Record<Key, () => void>> = {};
  actionMap: Record<string, ActionHandler> = {};
  left: SoftAction | null = null;
  right: SoftAction | null = null;

  constructor() {
    this.id = ++counter;
  }
  alive(): boolean {
    return active === this;
  }
  title(text: string, opts: { back?: boolean; sub?: string } = {}): void {
    if (!this.alive()) return;
    if (titleHook) titleHook(text, opts.back !== false, opts.sub || "");
  }
  content(): HTMLElement {
    return byId("app") as HTMLElement;
  }
  render(markup: SafeHtml): void {
    if (!this.alive()) return;
    const app = this.content();
    // A repaint of the same screen (fresh data after the cached paint)
    // replaces the focused element; put focus back on the same item, or the
    // D-pad is left on nothing and OK does nothing.
    const had = document.activeElement as HTMLElement | null;
    const keyed =
      had && had !== app && app.contains(had)
        ? closest(had, "[data-key]")
        : null;
    const key = keyed ? keyed.getAttribute("data-key") : null;
    setHtml(app, markup);
    if (key && !app.contains(document.activeElement)) focusByKey(key);
  }
  onLeave(fn: () => void): void {
    if (this.alive()) this.leaves.push(fn);
    else fn();
  }
  keys(map: Partial<Record<Key, () => void>>): void {
    for (const k in map)
      if (map.hasOwnProperty(k)) this.keyMap[k as Key] = map[k as Key];
  }
  act(name: string, fn: ActionHandler): void {
    this.actionMap[name] = fn;
  }
  softkeys(opts: {
    left?: SoftAction | null;
    center?: string;
    right?: SoftAction | null;
  }): void {
    if (opts.left !== undefined) this.left = opts.left;
    if (opts.right !== undefined) this.right = opts.right;
    if (!this.alive()) return;
    setPageSoftkeys({
      left: this.left ? this.left.label : "Menu",
      center: opts.center !== undefined ? opts.center : "Select",
      right: this.right ? this.right.label : "",
    });
  }
  loading(message = "Loading…"): void {
    this.render(
      html`<div class="state state-loading" role="status">
        <span class="spinner" aria-hidden="true"></span><span>${message}</span>
      </div>`
    );
  }
  error(message: string, retry?: () => void): void {
    if (!this.alive()) return;
    this.render(
      html`<div class="state state-error" role="alert">
        ${icon("info")}
        <p>${message}</p>
        ${retry
          ? html`<button
              type="button"
              class="btn primary"
              data-act="screen-retry"
            >
              Try again
            </button>`
          : ""}
      </div>`
    );
    if (retry) this.act("screen-retry", retry);
  }
  empty(message: SafeHtml | string, iconName = "info"): void {
    this.render(
      html`<div class="state state-empty">
        ${icon(iconName)}
        <p>${message}</p>
      </div>`
    );
  }
  compose(target: string | null, label = "New"): void {
    if (!this.alive()) return;
    if (composeHook) composeHook(target, label);
  }
}

export function beginScreen(): Screen {
  if (active) {
    const old = active;
    active = null;
    for (let i = 0; i < old.leaves.length; i++) {
      try {
        old.leaves[i]();
      } catch {
        // A failing cleanup must not block the next screen.
      }
    }
  }
  const s = new ScreenImpl();
  active = s;
  setPageSoftkeys({ left: "Menu", center: "Select", right: "" });
  if (composeHook) composeHook(null, "");
  return s;
}

export function currentScreen(): Screen | null {
  return active;
}

export function screenKey(key: Key): boolean {
  if (!active) return false;
  const fn = active.keyMap[key];
  if (!fn) return false;
  fn();
  return true;
}

export function screenSoftkey(which: "left" | "right"): boolean {
  if (!active) return false;
  const a = which === "left" ? active.left : active.right;
  if (!a) return false;
  a.run();
  return true;
}

// The screen's own soft-key actions, repeated in the menu for phones whose
// soft keys never reach the page.
export function screenSoftActions(): SoftAction[] {
  if (!active) return [];
  const out: SoftAction[] = [];
  if (active.left) out.push(active.left);
  if (active.right) out.push(active.right);
  return out;
}

export function runAction(name: string, el: HTMLElement, e: Event): boolean {
  const fn = active && active.actionMap[name];
  if (!fn) return false;
  fn(el, e);
  return true;
}
