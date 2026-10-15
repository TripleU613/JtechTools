import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import { service } from "@ember/service";
import { type TrustedHTML, trustHTML } from "@ember/template";
import { settings, themePrefix } from "virtual:theme";
import { avatarUrl } from "discourse/lib/avatar-utils";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";

interface OnlineUser {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
}

// The parts of the Who's Online plugin's service used here
interface WhosOnline {
  enabled: boolean;
  users?: OnlineUser[];
  count: number;
}

interface OnlineSiteSettings {
  whos_online_minimum_display?: number;
}

interface Face {
  user: OnlineUser;
  href: string;
  src: string;
  style: TrustedHTML;
}

// The most faces the row shows; "Online: 3" counts everyone
const MOST = 40;

// Who's Online (the plugin) puts a row of avatars over the topic list, in the
// way of the tabs. With setting online_box it's beside the tabs' dropdown
// instead: "Online: 3", which opens out sideways into the faces of the
// people online, in a row into the room up to New Topic, each a link to their
// profile. More than fit fade out at the row's end. It shows to the people the plugin shows its
// row to, and only while as many people are online as the plugin's own
// minimum.
export default class JtOnlineBox extends Component {
  @service declare siteSettings: OnlineSiteSettings;

  @tracked open = false;

  whosOnline = getOwner(this)?.lookup("service:whos-online") as
    | WhosOnline
    | undefined;

  get shown(): boolean {
    const online = this.whosOnline;
    return (
      settings.online_box &&
      !!online?.enabled &&
      online.count > 0 &&
      online.count >= (this.siteSettings.whos_online_minimum_display || 1)
    );
  }

  get count(): number {
    return this.whosOnline?.count ?? 0;
  }

  get faces(): Face[] {
    return (this.whosOnline?.users ?? []).slice(0, MOST).map((user, i) => ({
      user,
      href: getURL(`/u/${user.username}`),
      src: avatarUrl(user.avatar_template, "medium"),
      style: trustHTML(`--jt-i: ${i}`),
    }));
  }

  @action
  toggle() {
    this.open = !this.open;
  }

  <template>
    {{#if this.shown}}
      <span class="jt-online-box">
        <button
          aria-expanded={{if this.open "true" "false"}}
          class="jt-online-box__label"
          type="button"
          {{on "click" this.toggle}}
        >
          {{i18n (themePrefix "jt.online.box") count=this.count}}
        </button>
        {{#if this.open}}
          <span class="jt-online-box__people">
            {{#each this.faces as |face|}}
            <a
              class="jt-online-box__person"
              href={{face.href}}
              style={{face.style}}
              title={{if face.user.name face.user.name face.user.username}}
            >
              <img
                alt={{face.user.username}}
                class="jt-online-box__face"
                src={{face.src}}
              />
            </a>
          {{/each}}
          </span>
        {{/if}}
      </span>
    {{/if}}
  </template>
}
