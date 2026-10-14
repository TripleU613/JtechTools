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

// Faces in the closed box; the open one shows up to MOST
const STACKED = 3;
const MOST = 30;

// Who's Online (the plugin) puts a row of avatars over the topic list, in the
// way of the tabs. With setting online_box it's a box beside the tabs'
// dropdown instead: a few faces stacked, in grey, and the count. Clicked, it
// opens to the right with everyone online in full colour, one face after
// another, each a link to their profile. It shows to the people the plugin
// shows its row to, and only while as many people are online as the plugin's
// own minimum.
export default class JtOnlineBox extends Component {
  @service declare siteSettings: OnlineSiteSettings;

  @tracked open = false;
  box: HTMLElement | null = null;

  whosOnline = getOwner(this)?.lookup("service:whos-online") as
    | WhosOnline
    | undefined;

  willDestroy() {
    super.willDestroy();
    document.removeEventListener("click", this.outside, true);
    document.removeEventListener("keydown", this.escape);
  }

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

  get stacked(): Face[] {
    return this.faces.slice(0, STACKED);
  }

  @action
  toggle(event: Event) {
    this.box = (event.currentTarget as HTMLElement).closest(".jt-online-box");
    if (this.open) {
      this.close();
      return;
    }
    // The open box runs to the window's right edge at most
    const left = this.box?.getBoundingClientRect().left ?? 0;
    this.box?.style.setProperty(
      "--jt-online-room",
      `${window.innerWidth - left - 12}px`
    );
    this.open = true;
    document.addEventListener("click", this.outside, true);
    document.addEventListener("keydown", this.escape);
  }

  @action
  close() {
    this.open = false;
    document.removeEventListener("click", this.outside, true);
    document.removeEventListener("keydown", this.escape);
  }

  @action
  outside(event: MouseEvent) {
    if (!this.box?.contains(event.target as Node)) {
      this.close();
    }
  }

  @action
  escape(event: KeyboardEvent) {
    if (event.key === "Escape") {
      this.close();
    }
  }

  <template>
    {{#if this.shown}}
      <span class="jt-online-box {{if this.open '--open'}}">
        <button
          aria-expanded={{if this.open "true" "false"}}
          class="btn jt-online-box__toggle"
          title={{i18n (themePrefix "jt.online.title") count=this.count}}
          type="button"
          {{on "click" this.toggle}}
        >
          <span class="jt-online-box__stack">
            {{#each this.stacked as |face|}}
              <img alt="" class="jt-online-box__face" src={{face.src}} />
            {{/each}}
          </span>
          <span class="jt-online-box__count">{{this.count}}</span>
        </button>
        <span class="jt-online-box__people" inert={{if this.open false true}}>
          <button
            class="btn btn-transparent jt-online-box__label"
            type="button"
            {{on "click" this.close}}
          >
            {{i18n (themePrefix "jt.online.title") count=this.count}}
          </button>
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
