// Small DOM helpers. Queries return real arrays (NodeList#forEach is
// missing on old engines), and setHtml only accepts SafeHtml.

import type { SafeHtml } from "./html.ts";

export function byId<T extends HTMLElement = HTMLElement>(
  id: string
): T | null {
  return document.getElementById(id) as T | null;
}

export function $<T extends HTMLElement = HTMLElement>(
  selector: string,
  root: ParentNode = document
): T | null {
  return root.querySelector(selector) as T | null;
}

export function $$<T extends HTMLElement = HTMLElement>(
  selector: string,
  root: ParentNode = document
): T[] {
  const list = root.querySelectorAll(selector);
  const out: T[] = [];
  for (let i = 0; i < list.length; i++) out.push(list[i] as T);
  return out;
}

export function setHtml(el: Element, markup: SafeHtml): void {
  el.innerHTML = markup.value;
}

export function appendHtml(el: Element, markup: SafeHtml): void {
  el.insertAdjacentHTML("beforeend", markup.value);
}

export function prependHtml(el: Element, markup: SafeHtml): void {
  el.insertAdjacentHTML("afterbegin", markup.value);
}

// Builds an element from markup (first element of it).
export function fromHtml(markup: SafeHtml): HTMLElement | null {
  const box = document.createElement("div");
  box.innerHTML = markup.value;
  return box.firstElementChild as HTMLElement | null;
}

export function toggleClass(el: Element, name: string, on: boolean): void {
  if (on) el.classList.add(name);
  else el.classList.remove(name);
}

export function show(el: HTMLElement | null, visible: boolean): void {
  if (el) el.style.display = visible ? "" : "none";
}

export function isVisible(el: HTMLElement): boolean {
  if (el.offsetWidth > 0 || el.offsetHeight > 0) return true;
  const rects = el.getClientRects();
  return rects.length > 0;
}

export function topbarHeight(): number {
  const bar = byId("topbar");
  return bar ? bar.offsetHeight : 0;
}

export function bottomBarHeight(): number {
  const bar = byId("softkeys");
  return bar && isVisible(bar) ? bar.offsetHeight : 0;
}

// Scrolls just enough to show `el` below the fixed top bar and above the
// soft-key bar, like a native list does.
export function revealElement(
  el: HTMLElement,
  scroller?: HTMLElement | null
): void {
  if (scroller) {
    const top = el.offsetTop;
    const bottom = top + el.offsetHeight;
    if (top < scroller.scrollTop) scroller.scrollTop = top;
    else if (bottom > scroller.scrollTop + scroller.clientHeight)
      scroller.scrollTop = bottom - scroller.clientHeight;
    return;
  }
  const rect = el.getBoundingClientRect();
  const topLimit = topbarHeight() + 4;
  const bottomLimit =
    (window.innerHeight || document.documentElement.clientHeight) -
    bottomBarHeight() -
    4;
  const room = bottomLimit - topLimit;
  if (rect.height > room || rect.top < topLimit) {
    window.scrollBy(0, rect.top - topLimit);
  } else if (rect.bottom > bottomLimit) {
    window.scrollBy(0, rect.bottom - bottomLimit);
  }
}

export function scrollY(): number {
  return window.pageYOffset || document.documentElement.scrollTop || 0;
}

export function viewportHeight(): number {
  return window.innerHeight || document.documentElement.clientHeight;
}

export function nearBottom(margin: number): boolean {
  const doc = document.documentElement;
  const height = Math.max(document.body.scrollHeight, doc.scrollHeight);
  return scrollY() + viewportHeight() >= height - margin;
}

export function listen<K extends keyof DocumentEventMap>(
  target: Document | Window | HTMLElement,
  type: K,
  handler: (e: DocumentEventMap[K]) => void,
  capture = false
): () => void {
  target.addEventListener(type, handler as EventListener, capture);
  return () =>
    target.removeEventListener(type, handler as EventListener, capture);
}

export function debounce<A extends unknown[]>(
  fn: (...args: A) => void,
  ms: number
): (...args: A) => void {
  let timer: ReturnType<typeof setTimeout> | null = null;
  return (...args: A) => {
    if (timer) clearTimeout(timer);
    timer = setTimeout(() => {
      timer = null;
      fn(...args);
    }, ms);
  };
}

export function copyText(text: string): boolean {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.setAttribute("readonly", "");
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } catch {
    ok = false;
  }
  document.body.removeChild(ta);
  return ok;
}
