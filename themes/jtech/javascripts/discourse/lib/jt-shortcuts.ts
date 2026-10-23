// Keyboard shortcuts for the command menu's commands
// (components/jt-command-menu), which shows each beside its command.
//
// Most are core's own (services/keyboard-shortcuts). The rest are the
// theme's, bound by api-initializers/jt-shortcuts in core's "jump to" style:
// `g` then a key, and advanced search held together with ⌘K's own keys. Like
// core's, they work anywhere outside a text field, so not while typing in the
// open menu: there `g` then a letter is how "google" or "guide" begins.
export const CORE_SHORTCUTS = {
  new_topic: "c",
  latest: "g l",
  new: "g n",
  unread: "g u",
  top: "g t",
  categories: "g c",
  bookmarks: "g b",
  messages: "g m",
  profile: "g p",
  shortcuts: "?",
  bulk_select: "shift+b",
} as const;

export const JT_SHORTCUTS = {
  tags: "g g",
  notifications: "g i",
  preferences: "g e",
  admin: "g a",
  toggle_theme: "g o",
  advanced_search: "mod+shift+k",
} as const;
