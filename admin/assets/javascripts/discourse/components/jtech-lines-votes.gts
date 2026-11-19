import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import type Owner from "@ember/owner";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";

interface Voter {
  username: string;
  value: number;
  at: string;
}

interface AdVotes {
  name: string;
  key: string;
  up: number;
  down: number;
  voters: Voter[];
}

// The Ads tab's thumbs: per ad, how many up and down and who gave which.
// Admins only (GET /jtech-lines/votes); the ads themselves show no counts.
export default class JtechLinesVotes extends Component {
  @tracked ads: AdVotes[] = [];
  @tracked loaded = false;

  constructor(owner: Owner, args: object) {
    super(owner, args);
    this.#load();
  }

  get anyVotes(): boolean {
    return this.ads.some((ad) => ad.voters.length > 0);
  }

  async #load() {
    try {
      const result = await ajax("/jtech-lines/votes");
      this.ads = result.ads;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loaded = true;
    }
  }

  <template>
    <section class="jtech-lines-votes admin-config-area-card">
      <h3>{{i18n "admin.jtech_tools.lines_votes.title"}}</h3>
      <p>{{i18n "admin.jtech_tools.lines_votes.about"}}</p>
      {{#if this.loaded}}
        {{#if this.anyVotes}}
          {{#each this.ads as |ad|}}
            <details>
              <summary>
                <b>{{ad.name}}</b>
                <span class="jtech-lines-votes__count">↑
                  {{ad.up}}
                  · ↓
                  {{ad.down}}</span>
              </summary>
              <ul>
                {{#each ad.voters as |voter|}}
                  <li>
                    <a href="/u/{{voter.username}}">@{{voter.username}}</a>
                    {{if
                      (gt voter.value 0)
                      (i18n "admin.jtech_tools.lines_votes.up")
                      (i18n "admin.jtech_tools.lines_votes.down")
                    }}
                  </li>
                {{/each}}
              </ul>
            </details>
          {{/each}}
        {{else}}
          <p>{{i18n "admin.jtech_tools.lines_votes.none"}}</p>
        {{/if}}
      {{/if}}
    </section>
  </template>
}

function gt(a: number, b: number): boolean {
  return a > b;
}
