import { settings } from "virtual:theme";
import { apiInitializer } from "discourse/lib/api";
import JtPostBadges from "../components/jt-post-badges.gts";

export default apiInitializer((api) => {
  if (settings.post_badges) {
    api.renderAfterWrapperOutlet("post-meta-data-poster-name", JtPostBadges);
  }
});
