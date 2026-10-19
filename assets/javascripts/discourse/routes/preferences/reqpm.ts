import type Controller from "@ember/controller";
import type RouterService from "@ember/routing/router-service";
import { service } from "@ember/service";
import type User from "discourse/models/user";
import RestrictedUserRoute from "discourse/routes/restricted-user";
import type ReqpmService from "../../services/reqpm.ts";

// /u/:username/preferences/reqpm — your own contact card, in settings.
export default class PreferencesReqpmRoute extends RestrictedUserRoute {
  @service declare reqpm: ReqpmService;
  @service declare router: RouterService;

  showFooter = true;

  setupController(controller: Controller, user: User) {
    if (!this.reqpm.available) {
      return this.router.transitionTo("preferences.account", user);
    }
    controller.set("model", user);
  }
}
