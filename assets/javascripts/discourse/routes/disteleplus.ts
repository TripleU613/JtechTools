import type Transition from "@ember/routing/transition";
import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";
import { i18n } from "discourse-i18n";
import DisteleplusService, {
  DisteleplusMessage,
} from "../services/disteleplus.ts";

// router.js's URL transition intent; the Transition types keep it opaque.
interface URLTransitionIntent {
  url?: string;
}

// Full-page conversation. Like core Chat's route: on desktop, when the drawer
// is the preferred mode and this is an in-app transition (not a hard load or
// an explicit "open in full page"), open the drawer instead of navigating.
export default class DisteleplusRoute extends DiscourseRoute {
  @service declare disteleplus: DisteleplusService;

  titleToken(): string {
    return i18n("disteleplus.title");
  }

  beforeModel(transition: Transition): void {
    this.disteleplus.storeAppURL();
    // Deep link (#m<id>) from a notification or a copied message link. The
    // Ember router drops the hash, so read it off the transition/URL here
    // and stash it for whichever surface (drawer or full page) opens.
    const hash =
      (transition.intent as URLTransitionIntent | null)?.url?.match(
        /#m(\d+)/
      ) || window.location.hash.match(/^#m(\d+)$/);
    if (hash) {
      this.disteleplus.requestJump(Number(hash[1]));
    }
    const fullPageReload = !transition.from;
    if (this.disteleplus.isDrawerPreferred && !fullPageReload) {
      transition.abort();
      this.disteleplus.openDrawer();
      return;
    }
    this.disteleplus.closeDrawer();
  }

  model(): Promise<DisteleplusMessage[]> {
    return this.disteleplus.ensureLoaded();
  }

  activate(transition: Transition): void {
    super.activate(transition);
    document.documentElement.classList.add("has-full-page-disteleplus");
    document.body.classList.add("has-full-page-disteleplus");
  }

  deactivate(transition: Transition): void {
    super.deactivate(transition);
    document.documentElement.classList.remove("has-full-page-disteleplus");
    document.body.classList.remove("has-full-page-disteleplus");
  }
}
