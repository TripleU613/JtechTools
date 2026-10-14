import { apiInitializer } from "discourse/lib/api";
import { VANILLA_CLASS } from "../lib/jt-vanilla";

// The topic list's tabs (Latest, New, Unread, Top…) are one dropdown on a
// computer too, as on a phone: what Discourse's Compact Nav component does.
// As a row they ran out of room beside the filters and New Topic and had to
// scroll sideways. Under a Discourse palette (lib/jt-vanilla) they're stock
// Discourse's: a row on a computer, the dropdown on a phone.
export default apiInitializer((api) => {
  api.registerValueTransformer(
    "navigation-bar-dropdown-mode",
    ({ value }: { value: boolean }) =>
      value || !document.documentElement.classList.contains(VANILLA_CLASS)
  );
});
