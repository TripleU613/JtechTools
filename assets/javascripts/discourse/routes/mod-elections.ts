import type Transition from "@ember/routing/transition";
import { service } from "@ember/service";
import type User from "discourse/models/user";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";

// /elections — data loads inside the component, so switching to a past
// election (?id=) doesn't reload the route.
export default class ModElectionsRoute extends DiscourseRoute {
  @service declare currentUser: User | null;

  queryParams = {
    id: { replace: true },
  };

  // Members only: a visitor is sent to log in, and comes back here after.
  beforeModel(transition: Transition) {
    if (!this.currentUser) {
      transition.send(false, "showLogin");
    }
  }

  titleToken(): string {
    return i18n("mod_elections.title");
  }
}
