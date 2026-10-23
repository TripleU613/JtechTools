import { trackedMap } from "@ember/reactive/collections";

// A post's menu on a phone stays on one line: the buttons that don't fit go
// into ⋯ (api-initializers/jt-phone-post-menu). How many fit, by post id,
// measured by components/jt-post-menu-room once the menu is on the page.
export const menuRoom = trackedMap<number, number>();

// A button on a phone's line: 34px and the 2px gap after it
// (stylesheets/jt-phone-post-menu)
export const BUTTON = 36;

// The buttons that fit in a width
export function buttonsIn(width: number): number {
  // n buttons are n widths less the gap after the last
  return Math.max(0, Math.floor((width + 2) / BUTTON));
}
