import Component from "@glimmer/component";
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
// instead: "Online: 3" and the faces of the people online, spread out in a
// row into the room up to New Topic, each a link to their profile. More than
// fit fade out at the row's end. It shows to the people the plugin shows its
// row to, and only while as many people are online as the plugin's own
// minimum.
export default class JtOnlineBox extends Component {
  @service declare siteSettings: OnlineSiteSettings;

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

  <template>
    {{#if this.shown}}
      <span class="jt-online-box">
        <span class="jt-online-box__label">
          {{i18n (themePrefix "jt.online.box") count=this.count}}
        </span>
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
      </span>
    {{/if}}
  </template>
}
