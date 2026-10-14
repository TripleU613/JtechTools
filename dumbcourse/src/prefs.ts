// Device preferences: how Dumbcourse looks and behaves on this phone.
// They stay on the device (not the account), so a big-text setting on a
// flip phone does not follow you to your computer.

import {
  onMediaChange,
  prefersLight,
  prefersReducedMotion,
  screenShape,
} from "./compat.ts";
import { settings } from "./config.ts";
import type { Key } from "./keys.ts";
import { getJson, getRaw, removeRaw, setJson } from "./storage.ts";

export type Theme = "auto" | "light" | "dark";
export type ImageMode = "show" | "tap" | "hide";
export type Toggle3 = "auto" | "on" | "off";

export interface Prefs {
  theme: Theme;
  textSize: number;
  density: "compact" | "comfortable";
  avatars: boolean;
  images: ImageMode;
  excerpts: boolean;
  softkeys: Toggle3;
  // Set once this device presses a D-pad or soft key.
  keypad: boolean;
  live: boolean;
  defaultView: string;
  hints: boolean;
  // Keys taught on the Phone keys screen: key signature → key.
  keymap: Record<string, Key>;
}

const KEY = "prefs";
export const TEXT_SIZES = [80, 90, 100, 110, 125, 140, 160];

function defaults(): Prefs {
  const theme =
    settings.defaultTheme === "light" || settings.defaultTheme === "dark"
      ? settings.defaultTheme
      : "auto";
  return {
    theme: theme as Theme,
    textSize: 100,
    density: "comfortable",
    avatars: true,
    images: "show",
    excerpts: true,
    softkeys: "auto",
    keypad: false,
    live: true,
    defaultView: "",
    hints: true,
    keymap: {},
  };
}

function load(): Prefs {
  const saved = getJson<Partial<Prefs>>(KEY, {});
  const d = defaults();
  // One-time move from the old app's keys.
  const legacyTheme = getRaw("jt_theme");
  const legacyScale = getRaw("jt_scale");
  if (legacyTheme === "light" || legacyTheme === "dark")
    saved.theme = saved.theme || (legacyTheme as Theme);
  if (legacyScale && !saved.textSize) {
    const n = parseInt(legacyScale, 10);
    if (n >= 50 && n <= 200) saved.textSize = n;
  }
  const out = d as unknown as Record<string, unknown>;
  const given = saved as unknown as Record<string, unknown>;
  for (const k in out)
    if (
      out.hasOwnProperty(k) &&
      given[k] !== undefined &&
      typeof given[k] === typeof out[k]
    )
      out[k] = given[k];
  return out as unknown as Prefs;
}

export const prefs: Prefs = load();
const listeners: Array<() => void> = [];

export function onPrefsChange(fn: () => void): void {
  listeners.push(fn);
}

export function setPref<K extends keyof Prefs>(key: K, value: Prefs[K]): void {
  prefs[key] = value;
  setJson(KEY, prefs);
  applyPrefs();
  for (let i = 0; i < listeners.length; i++) listeners[i]();
}

export function isLight(): boolean {
  if (prefs.theme === "light") return true;
  if (prefs.theme === "dark") return false;
  return prefersLight();
}

// 240x320, 480x640 (0.75) and 320x480 (0.67) are in; 480x800 (0.6) and
// every modern phone are out.
const KEYPAD_SHAPE = 0.65;

export function softkeysVisible(): boolean {
  if (prefs.softkeys === "on") return true;
  if (prefs.softkeys === "off") return false;
  // Touch phones are as narrow as keypad phones in CSS pixels, but their
  // screens are tall (about 9:20) where keypad phones are 3:4.
  const w = window.innerWidth || document.documentElement.clientWidth;
  if (w > 480) return false;
  const shape = screenShape();
  return prefs.keypad || !shape || shape >= KEYPAD_SHAPE;
}

const NAV_KEYS: Key[] = [
  "up",
  "down",
  "left",
  "right",
  "softleft",
  "softright",
];

export function noteKey(key: Key, typing: boolean): void {
  if (prefs.keypad || typing || NAV_KEYS.indexOf(key) < 0) return;
  setPref("keypad", true);
}

export function applyPrefs(): void {
  const root = document.documentElement;
  const classes = (root.className || "")
    .split(/\s+/)
    .filter(
      (c) =>
        c &&
        !/^(light|dark|compact|no-avatars|with-softkeys|reduce-motion)$/.test(c)
    );
  classes.push(isLight() ? "light" : "dark");
  if (prefs.density === "compact") classes.push("compact");
  if (!prefs.avatars) classes.push("no-avatars");
  if (softkeysVisible()) classes.push("with-softkeys");
  if (prefersReducedMotion()) classes.push("reduce-motion");
  root.className = classes.join(" ");
  root.style.fontSize = (15 * prefs.textSize) / 100 + "px";
  const meta = document.querySelector(
    'meta[name="theme-color"]'
  ) as HTMLMetaElement | null;
  // The page's own background: the palette's, or the stylesheet's on browsers
  // without custom properties
  if (meta) meta.content = window.getComputedStyle(document.body).backgroundColor;
}

export function watchSystemTheme(): void {
  onMediaChange("(prefers-color-scheme: light)", () => {
    if (prefs.theme === "auto") applyPrefs();
  });
}

export function forgetLegacyKeys(): void {
  const legacy = [
    "jt_theme",
    "jt_scale",
    "jt_session_token",
    "jt_csrf",
    "jt_cookies",
    "jt_username",
    "jt_user_id",
    "jt_logged_in",
    "jt_admin",
    "jt_moderator",
    "jt_api_cache",
    "jt_api_cache_owner",
    "jt_read_topics",
    "jt_image_cache",
    "jt_emoji_map",
    "jt_drafts",
  ];
  for (let i = 0; i < legacy.length; i++) removeRaw(legacy[i]);
}
