import { apiInitializer } from "discourse/lib/api";

// The topic list's tabs (Latest, New, Unread, Top…) are one dropdown on a
// computer too, as on a phone: what Discourse's Compact Nav component does.
// As a row they ran out of room beside the filters and New Topic and had to
// scroll sideways.
export default apiInitializer((api) => {
  api.registerValueTransformer("navigation-bar-dropdown-mode", () => true);
});
