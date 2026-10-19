import Component from "@glimmer/component";
import { htmlSafe, type SafeString } from "@ember/template";
import DModal from "discourse/components/d-modal";
import { getURLWithCDN } from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import type { MessagePoll, PollVoter } from "../services/disteleplus.ts";

const AVATAR_SIZE = 48;

interface DisteleplusPollStatsSignature {
  Args: {
    model: { poll: MessagePoll; voters: Record<string, PollVoter[]> };
    closeModal: () => void;
  };
}

interface StatsOption {
  html: string;
  votes: number;
  percent: number;
  barStyle: SafeString;
  voters: { username: string; name: string; avatarUrl: string | null }[];
}

// "View stats" for a conversation poll: every option sorted by votes with
// its share and the full voter list (public polls). Data comes from core's
// /polls/voters endpoint, fetched by the opener.
export default class DisteleplusPollStats extends Component<DisteleplusPollStatsSignature> {
  get poll(): MessagePoll {
    return this.args.model.poll;
  }

  get totalVotes(): number {
    return (this.poll.options || []).reduce(
      (sum, option) => sum + (option.votes || 0),
      0
    );
  }

  get options(): StatsOption[] {
    const votersByDigest = this.args.model.voters || {};
    const total = this.totalVotes;
    return (this.poll.options || [])
      .map((option) => ({
        html: option.html,
        votes: option.votes || 0,
        percent: total ? Math.round(((option.votes || 0) * 100) / total) : 0,
        barStyle: htmlSafe(
          `width:${total ? Math.round(((option.votes || 0) * 100) / total) : 0}%`
        ),
        voters: (votersByDigest[option.id] || []).map((voter) => ({
          username: voter.username,
          name: voter.name || voter.username,
          avatarUrl: voter.avatar_template
            ? getURLWithCDN(
                voter.avatar_template.replace("{size}", String(AVATAR_SIZE))
              )
            : null,
        })),
      }))
      .sort((a, b) => b.votes - a.votes);
  }

  get subtitle(): string {
    return i18n("disteleplus.poll.voters", { count: this.poll.voters || 0 });
  }

  <template>
    <DModal
      class="disteleplus-poll-stats"
      @closeModal={{@closeModal}}
      @title={{i18n "disteleplus.poll.stats_title"}}
    >
      <:body>
        <p class="disteleplus-poll-stats__subtitle">{{this.subtitle}}</p>
        {{#each this.options as |option|}}
          <div class="disteleplus-poll-stats__option">
            <div class="disteleplus-poll-stats__row">
              <span class="disteleplus-poll-stats__label">
                {{htmlSafe option.html}}
              </span>
              <span class="disteleplus-poll-stats__count">
                {{option.votes}}
                ·
                {{option.percent}}%
              </span>
            </div>
            <span class="disteleplus-poll-stats__bar-back">
              <span
                class="disteleplus-poll-stats__bar"
                style={{option.barStyle}}
              />
            </span>
            {{#if option.voters.length}}
              <ul class="disteleplus-poll-stats__voters">
                {{#each option.voters as |voter|}}
                  <li title={{voter.username}}>
                    {{#if voter.avatarUrl}}
                      <img alt="" src={{voter.avatarUrl}} />
                    {{/if}}
                    {{voter.name}}
                  </li>
                {{/each}}
              </ul>
            {{/if}}
          </div>
        {{/each}}
      </:body>
    </DModal>
  </template>
}
