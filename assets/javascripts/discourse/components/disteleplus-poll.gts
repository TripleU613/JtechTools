import Component from "@glimmer/component";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { htmlSafe, type SafeString } from "@ember/template";
import icon from "discourse/helpers/d-icon";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { getURLWithCDN } from "discourse/lib/get-url";
import type ModalService from "discourse/services/modal";
import { i18n } from "discourse-i18n";
import DisteleplusService, {
  DisteleplusCurrentUser,
  DisteleplusMessage,
  MessagePoll,
  PollOption,
} from "../services/disteleplus.ts";
import DisteleplusPollStats from "./disteleplus-poll-stats.gts";

interface DisteleplusPollSignature {
  Args: { message: DisteleplusMessage };
}

interface VoterAvatar {
  username: string;
  name: string;
  url: string | null;
}

interface PollOptionRow extends PollOption {
  percent: number;
  barStyle: SafeString;
  voterAvatars: VoterAvatar[];
  extraVoters: number;
  voterNames: string;
}

const AVATAR_SIZE = 48;
const VOTER_AVATARS_SHOWN = 5;

// Poll widget inside a conversation message. The data is a real core
// discourse-poll on the hidden backing post; voting goes through core's
// /polls/vote endpoints, and other viewers' votes stream in over core's
// poll MessageBus channel (wired in the disteleplus service).
export default class DisteleplusPoll extends Component<DisteleplusPollSignature> {
  @service declare disteleplus: DisteleplusService;
  @service declare currentUser: DisteleplusCurrentUser | null;
  @service declare modal: ModalService;

  // Close/reopen mirrors core's rule: the backing post's author or staff.
  get canManage(): boolean {
    return this.message.mine || !!this.currentUser?.staff;
  }

  get showStats(): boolean {
    return !!this.poll.public && (this.poll.voters || 0) > 0;
  }

  // Always read the live message from the service — bus updates replace
  // message objects wholesale.
  get message(): DisteleplusMessage {
    return (
      this.disteleplus.messages.find((m) => m.id === this.args.message.id) ||
      this.args.message
    );
  }

  get poll(): MessagePoll {
    return this.message.poll;
  }

  get multiple(): boolean {
    return this.poll.type === "multiple";
  }

  get totalVotes(): number {
    return (this.poll.options || []).reduce(
      (sum, option) => sum + (option.votes || 0),
      0
    );
  }

  get options(): PollOptionRow[] {
    const total = this.totalVotes;
    return (this.poll.options || []).map((option) => {
      const shown = (option.voters || [])
        .slice(0, VOTER_AVATARS_SHOWN)
        .map((voter) => ({
          username: voter.username,
          name: voter.name || voter.username,
          url: voter.avatar_template
            ? getURLWithCDN(
                voter.avatar_template.replace("{size}", String(AVATAR_SIZE))
              )
            : null,
        }))
        .filter((voter) => voter.url);
      return {
        ...option,
        percent: total ? Math.round((option.votes * 100) / total) : 0,
        barStyle: htmlSafe(
          `width:${total ? Math.round((option.votes * 100) / total) : 0}%`
        ),
        voterAvatars: shown,
        extraVoters: Math.max(0, (option.votes || 0) - shown.length),
        voterNames: (option.voters || [])
          .map((voter) => voter.name || voter.username)
          .join(", "),
      };
    });
  }

  get footerText(): string {
    const voters = i18n("disteleplus.poll.voters", {
      count: this.poll.voters || 0,
    });
    if (this.poll.closed) {
      return `${voters} · ${i18n("disteleplus.poll.closed")}`;
    }
    if (this.poll.close_at) {
      const remaining = new Date(this.poll.close_at).getTime() - Date.now();
      if (remaining > 0) {
        const hours = Math.round(remaining / 3_600_000);
        const label =
          hours >= 48
            ? i18n("disteleplus.poll.closes_days", {
                count: Math.round(hours / 24),
              })
            : hours >= 1
              ? i18n("disteleplus.poll.closes_hours", { count: hours })
              : i18n("disteleplus.poll.closes_soon");
        return `${voters} · ${label}`;
      }
    }
    return voters;
  }

  @action
  async pick(option: PollOption) {
    if (this.poll.closed) {
      return;
    }
    try {
      if (this.multiple) {
        const ids = new Set(
          this.poll.options
            .filter((candidate) => candidate.chosen)
            .map((candidate) => candidate.id)
        );
        if (ids.has(option.id)) {
          ids.delete(option.id);
        } else {
          ids.add(option.id);
        }
        if (ids.size === 0) {
          await this.disteleplus.retractPollVote(this.message);
        } else {
          await this.disteleplus.votePoll(this.message, [...ids]);
        }
      } else if (option.chosen) {
        await this.disteleplus.retractPollVote(this.message);
      } else {
        await this.disteleplus.votePoll(this.message, [option.id]);
      }
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async toggleStatus() {
    try {
      await this.disteleplus.togglePollStatus(
        this.message,
        this.poll.closed ? "open" : "closed"
      );
    } catch (error) {
      popupAjaxError(error);
    }
  }

  @action
  async openStats() {
    try {
      const response = await this.disteleplus.fetchPollVoters(this.message);
      this.modal.show(DisteleplusPollStats, {
        model: { poll: this.poll, voters: response.voters || {} },
      });
    } catch (error) {
      popupAjaxError(error);
    }
  }

  <template>
    <div
      class="disteleplus-poll {{if this.poll.closed 'is-closed'}}"
      data-poll-post-id={{this.poll.post_id}}
    >
      <div class="disteleplus-poll__kind">
        {{icon "chart-simple"}}
        {{i18n
          (if
            this.multiple
            "disteleplus.poll.pick_many"
            "disteleplus.poll.pick_one"
          )
        }}
      </div>
      <div class="disteleplus-poll__options">
        {{#each this.options as |option|}}
          <button
            class="disteleplus-poll__option {{if option.chosen 'is-chosen'}}"
            disabled={{if this.poll.closed "disabled"}}
            type="button"
            {{on "click" (fn this.pick option)}}
          >
            <span class="disteleplus-poll__check">
              {{#if option.chosen}}{{icon "circle-check"}}{{else}}{{icon
                  "far-circle"
                }}{{/if}}
            </span>
            <span class="disteleplus-poll__main">
              <span class="disteleplus-poll__row">
                <span class="disteleplus-poll__label">
                  {{htmlSafe option.html}}
                </span>
                {{#if option.voterAvatars.length}}
                  <span
                    class="disteleplus-poll__voters"
                    title={{option.voterNames}}
                  >
                    {{#each option.voterAvatars as |voter|}}
                      <img alt={{voter.username}} src={{voter.url}} />
                    {{/each}}
                    {{#if option.extraVoters}}
                      <span class="disteleplus-poll__voters-more">
                        +{{option.extraVoters}}
                      </span>
                    {{/if}}
                  </span>
                {{/if}}
                <span class="disteleplus-poll__count">
                  {{option.percent}}%
                </span>
              </span>
              <span class="disteleplus-poll__bar-back">
                <span class="disteleplus-poll__bar" style={{option.barStyle}} />
              </span>
            </span>
          </button>
        {{/each}}
      </div>
      <div class="disteleplus-poll__footer">
        <span class="disteleplus-poll__footer-text">{{this.footerText}}</span>
        <span class="disteleplus-poll__footer-actions">
          {{#if this.showStats}}
            <button type="button" {{on "click" this.openStats}}>
              {{icon "chart-pie"}}
              {{i18n "disteleplus.poll.stats"}}
            </button>
          {{/if}}
          {{#if this.canManage}}
            <button type="button" {{on "click" this.toggleStatus}}>
              {{#if this.poll.closed}}
                {{icon "unlock"}}
                {{i18n "disteleplus.poll.reopen"}}
              {{else}}
                {{icon "lock"}}
                {{i18n "disteleplus.poll.close"}}
              {{/if}}
            </button>
          {{/if}}
        </span>
      </div>
    </div>
  </template>
}
