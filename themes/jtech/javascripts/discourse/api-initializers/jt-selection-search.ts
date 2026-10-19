import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import JtSelectionSearch from "../components/jt-selection-search.gts";

export default apiInitializer((api) => {
  if (settings.selection_search) {
    api.renderAfterWrapperOutlet("post-text-buttons", JtSelectionSearch);
  }
});
