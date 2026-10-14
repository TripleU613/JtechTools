// How tightly topic lists are set (Gmail's Density): default, the cards as
// they are; comfortable, cards without excerpt or picture; compact, one row a
// topic. Chosen in the sidebar's density menu, kept per browser, and shown as
// a class on <html> (jt-density-comfortable / jt-density-compact) that
// jt-cards.scss styles.

export const DENSITIES = ["default", "comfortable", "compact"] as const;
export type Density = (typeof DENSITIES)[number];

const KEY = "jt-density";

export function currentDensity(): Density {
  let stored: string | null = null;
  try {
    stored = window.localStorage.getItem(KEY);
  } catch {
    // storage blocked (private mode): the default
  }
  return (DENSITIES as readonly string[]).includes(stored || "")
    ? (stored as Density)
    : "default";
}

export function applyDensity(density: Density = currentDensity()): void {
  const root = document.documentElement;
  for (const other of DENSITIES) {
    root.classList.remove(`jt-density-${other}`);
  }
  if (density !== "default") {
    root.classList.add(`jt-density-${density}`);
  }
}

export function setDensity(density: Density): void {
  try {
    if (density === "default") {
      window.localStorage.removeItem(KEY);
    } else {
      window.localStorage.setItem(KEY, density);
    }
  } catch {
    // storage blocked: it still applies to this page
  }
  applyDensity(density);
}
