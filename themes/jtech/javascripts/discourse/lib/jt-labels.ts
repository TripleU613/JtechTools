import { themePrefix } from "virtual:theme";
import { i18n } from "discourse-i18n";

// The theme's strings are English only. Where a label is the same word core
// already has (or core's own word for the same command), core's key is used
// instead, so it comes in every language the forum offers: in Hebrew the
// command menu said "Latest", "Bookmarks", "Admin".
const CORE_KEYS: Record<string, string> = {
  "cmdk.new_topic": "share_target.new_topic",
  "cmdk.latest": "keyboard_shortcuts_help.jump_to.latest",
  "cmdk.new": "keyboard_shortcuts_help.jump_to.new",
  "cmdk.unread": "keyboard_shortcuts_help.jump_to.unread",
  "cmdk.top": "keyboard_shortcuts_help.jump_to.top",
  "cmdk.categories": "keyboard_shortcuts_help.jump_to.categories",
  "cmdk.tags": "tagging.tags",
  "cmdk.bookmarks": "keyboard_shortcuts_help.jump_to.bookmarks",
  "cmdk.messages": "keyboard_shortcuts_help.jump_to.messages",
  "cmdk.notifications": "user.notifications",
  "cmdk.profile": "keyboard_shortcuts_help.jump_to.profile",
  "cmdk.preferences": "user.preferences.title",
  "cmdk.admin": "admin_title",
  "cmdk.advanced_search": "search.open_advanced",
  "cmdk.group_categories": "search.categories",
  "header.messages": "user.private_messages",
  "header.notifications": "user.notifications",
};

// A theme label by its key under `jt.`: core's word when it has one
export function jtLabel(
  key: string,
  options?: Record<string, unknown>
): string {
  const core = CORE_KEYS[key];
  return core ? i18n(core) : i18n(themePrefix(`jt.${key}`), options);
}
