import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, hash } from "@ember/helper";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import { LinkTo } from "@ember/routing";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import icon from "discourse/helpers/d-icon";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { longDate, shortDateNoYear } from "discourse/lib/formatter";
import type MessageBusService from "discourse/services/message-bus";
import { i18n } from "discourse-i18n";
import ModElectionsService, {
  ModElection,
  ModElectionCandidate,
  ModElectionPage,
} from "../services/mod-elections";
import ModElectionsBallot from "./mod-elections-ballot";
import ModElectionsCandidate from "./mod-elections-candidate";
import ModElectionsResults from "./mod-elections-results";
import ModElectionsRun from "./mod-elections-run";

type StepState = "done" | "current" | "upcoming";

interface Step {
  id: string;
  label: string;
  date: string;
  state: StepState;
}

interface ModElectionsPageSignature {
  Args: {
    // The ?id= query param: a past election, or blank for the current one.
    electionId?: string | null;
  };
}

type MessageBus = MessageBusService & {
  subscribe(channel: string, callback: (data: unknown) => void): void;
  unsubscribe(channel: string, callback: (data: unknown) => void): void;
};

// Sent when an election moves to its next step (Lifecycle, Publisher).
const STATE_CHANNEL = "/jtech-elections/state";

const ORDER = ["nominating", "voting", "closed", "published"];
const HOUR = 36e5;

// A date as a day on the forum's calendar, wherever the reader is: an
// election that opens at midnight in New York opens on the 1st, not on the
// 31st for someone in California.
const calendarDay = (
  date: string,
  zone: string | undefined,
  options: Intl.DateTimeFormatOptions
): string => {
  try {
    return new Date(date).toLocaleDateString(
      document.documentElement.lang || undefined,
      { ...options, timeZone: zone }
    );
  } catch {
    // An unknown zone: the reader's own calendar is the next best thing.
    return shortDateNoYear(date);
  }
};

// "3 days left", "5 hours left", "Less than an hour left".
const timeLeft = (until: string): string | null => {
  const ms = new Date(until).getTime() - Date.now();
  if (ms <= 0) {
    return null;
  }
  if (ms < HOUR) {
    return i18n("mod_elections.time_left.soon");
  }
  if (ms < 48 * HOUR) {
    return i18n("mod_elections.time_left.hours", {
      count: Math.floor(ms / HOUR),
    });
  }
  return i18n("mod_elections.time_left.days", {
    count: Math.floor(ms / (24 * HOUR)),
  });
};

// /elections — what step the election is at, who's running, your part in
// it (running, or your ballot), and the results once they're published.
export default class ModElectionsPage extends Component<ModElectionsPageSignature> {
  @service declare modElections: ModElectionsService;
  @service declare messageBus: MessageBus;

  @tracked page: ModElectionPage | null = null;
  @tracked loading = true;

  // A step changed: reload, unless someone is reading an older election.
  onStateChange = (): void => {
    if (!this.args.electionId) {
      this.refresh();
    }
  };

  constructor(owner: Owner, args: ModElectionsPageSignature["Args"]) {
    super(owner, args);
    this.load();
    this.messageBus.subscribe(STATE_CHANNEL, this.onStateChange);
  }

  willDestroy() {
    super.willDestroy();
    this.messageBus.unsubscribe(STATE_CHANNEL, this.onStateChange);
  }

  get election(): ModElection | null {
    return this.page?.election || null;
  }

  get status(): string | null {
    return this.election?.status || null;
  }

  get candidates(): ModElectionCandidate[] {
    return this.election?.candidates || [];
  }

  get runningCount(): number {
    return this.candidates.filter((c) => c.status === "running").length;
  }

  // When the current step ends, beside its name at the top.
  get statusDetail(): string | null {
    const election = this.election;
    if (!election) {
      return null;
    }
    const ends =
      election.status === "nominating"
        ? election.voting_open_at
        : election.status === "voting"
          ? election.voting_close_at
          : null;
    if (!ends) {
      return null;
    }
    // The exact moment in the reader's own time, then how long that is.
    const until = i18n("mod_elections.until", { date: longDate(ends) });
    const left = timeLeft(ends);
    return left ? `${until} · ${left}` : until;
  }

  get steps(): Step[] {
    const election = this.election;
    if (!election || election.status === "cancelled") {
      return [];
    }
    const at = ORDER.indexOf(election.status);
    const state = (index: number): StepState =>
      at > index ? "done" : at === index ? "current" : "upcoming";
    const day = (date: string) =>
      calendarDay(date, this.page?.timezone, {
        month: "short",
        day: "numeric",
      });
    return [
      {
        id: "nominations",
        label: i18n("mod_elections.steps.nominations"),
        date: day(election.nominations_open_at),
        state: state(0),
      },
      {
        id: "voting",
        label: i18n("mod_elections.steps.voting"),
        date: day(election.voting_open_at),
        state: state(1),
      },
      {
        id: "results",
        label: i18n("mod_elections.steps.results"),
        date: day(election.voting_close_at),
        // "Counting" and "Results" are the same step on the strip.
        state: at >= 3 ? "done" : at === 2 ? "current" : "upcoming",
      },
    ];
  }

  // When the next one opens, once this one is over (or before the first).
  get nextOpening(): string | null {
    const next = this.page?.next_opening;
    if (!next || (this.status && ORDER.indexOf(this.status) < 3)) {
      return null;
    }
    return i18n("mod_elections.next_opening", {
      date: calendarDay(next, this.page?.timezone, {
        month: "long",
        day: "numeric",
        year: "numeric",
      }),
    });
  }

  // Whether your own ballot went into the count. Never what was on it.
  get receipt(): { text: string; voided: boolean } | null {
    const ballot = this.page?.me?.ballot;
    if (!ballot || (this.status !== "closed" && this.status !== "published")) {
      return null;
    }
    if (ballot.voided) {
      return {
        voided: true,
        text: i18n("mod_elections.receipt.voided", {
          reason: ballot.void_reason || "",
        }),
      };
    }
    return {
      voided: false,
      text: i18n(
        this.status === "closed"
          ? "mod_elections.receipt.in"
          : "mod_elections.receipt.counted"
      ),
    };
  }

  get canVote(): boolean {
    const me = this.page?.me;
    return !!me && this.status === "voting" && !me.vote_blocked;
  }

  get voteBlockedMessage(): string | null {
    const reason = this.page?.me?.vote_blocked;
    if (!reason) {
      return null;
    }
    return i18n(`mod_elections.blocked.${reason}`, {
      days: this.page?.limits.voter_min_account_age_days,
    });
  }

  get history() {
    const current = this.election?.id;
    return (this.page?.history || []).filter((row) => row.id !== current);
  }

  @action
  async load() {
    this.loading = true;
    try {
      this.page = await this.modElections.page(this.args.electionId);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  // In place, without the spinner flashing over the page.
  async refresh() {
    try {
      const page = await this.modElections.page(this.args.electionId);
      if (!this.isDestroying) {
        this.page = page;
      }
    } catch {
      // The next step change, or a reload, tries again.
    }
  }

  @action
  updated(page: ModElectionPage) {
    this.page = page;
  }

  <template>
    <div class="mod-elections" {{didUpdate this.load @electionId}}>
      <header class="mod-elections__header">
        <h1>{{i18n "mod_elections.title"}}</h1>
        {{#if this.election}}
          <span
            class="mod-elections-status mod-elections-status--{{this.status}}"
          >
            {{i18n (concat "mod_elections.status." this.status)}}
            {{#if this.statusDetail}}
              <span class="mod-elections-muted">{{this.statusDetail}}</span>
            {{/if}}
          </span>
        {{/if}}
      </header>

      <ConditionalLoadingSpinner @condition={{this.loading}}>
        {{#if this.election}}
          {{#if this.steps.length}}
            <ol class="mod-elections-steps">
              {{#each this.steps as |step|}}
                <li
                  class="mod-elections-steps__step mod-elections-steps__step--{{step.state}}"
                  data-step={{step.id}}
                >
                  <span class="mod-elections-steps__label">{{step.label}}</span>
                  <span class="mod-elections-steps__date">{{step.date}}</span>
                </li>
              {{/each}}
            </ol>
          {{/if}}

          <div class="mod-elections__meta">
            <span>{{icon "users"}}
              {{i18n "mod_elections.seats" count=this.election.seats}}</span>
            {{#if this.election.topic_url}}
              <a href={{this.election.topic_url}}>{{icon "far-comments"}}
                {{i18n "mod_elections.discussion"}}</a>
            {{/if}}
            {{#if this.nextOpening}}
              <span class="mod-elections__next">{{this.nextOpening}}</span>
            {{/if}}
          </div>

          {{#if this.receipt}}
            <p
              class="mod-elections-receipt
                {{if this.receipt.voided 'mod-elections-receipt--voided'}}"
            >
              {{icon (if this.receipt.voided "xmark" "check")}}
              {{this.receipt.text}}
            </p>
          {{/if}}

          {{#if (eq this.status "cancelled")}}
            <p class="mod-elections-panel">{{i18n
                "mod_elections.cancelled"
              }}</p>
          {{else if (eq this.status "published")}}
            {{#if this.election.result}}
              <ModElectionsResults
                @candidates={{this.election.candidates}}
                @result={{this.election.result}}
                @turnout={{this.election.turnout}}
              />
            {{/if}}
          {{else}}
            {{#if (eq this.status "nominating")}}
              {{#if this.page.me}}
                <ModElectionsRun
                  @election={{this.election}}
                  @limits={{this.page.limits}}
                  @me={{this.page.me}}
                  @onChange={{this.updated}}
                />
              {{/if}}
            {{else if (eq this.status "voting")}}
              {{#if this.canVote}}
                <ModElectionsBallot
                  @election={{this.election}}
                  @me={{this.page.me}}
                  @onChange={{this.updated}}
                />
              {{else if this.voteBlockedMessage}}
                <p class="mod-elections-panel mod-elections-muted">
                  {{this.voteBlockedMessage}}
                </p>
              {{/if}}
            {{else if (eq this.status "closed")}}
              <section class="mod-elections-panel">
                <h2>{{i18n "mod_elections.closed.title"}}</h2>
                <p class="mod-elections-muted">{{i18n
                    "mod_elections.closed.body"
                  }}</p>
              </section>
            {{/if}}

            {{#unless this.canVote}}
              <section class="mod-elections-candidates">
                <h2>
                  {{i18n "mod_elections.candidates.title"}}
                  <span class="mod-elections-count">{{this.runningCount}}</span>
                </h2>
                {{#each this.candidates as |candidate|}}
                  <ModElectionsCandidate @candidate={{candidate}} />
                {{else}}
                  <p class="mod-elections-muted">{{i18n
                      "mod_elections.candidates.none"
                    }}</p>
                {{/each}}
              </section>
            {{/unless}}
          {{/if}}
        {{else}}
          <div class="mod-elections-empty">
            {{icon "check-to-slot"}}
            <p>{{i18n "mod_elections.empty"}}</p>
            {{#if this.nextOpening}}
              <p class="mod-elections__next">{{this.nextOpening}}</p>
            {{/if}}
          </div>
        {{/if}}

        {{#if this.history.length}}
          <section class="mod-elections-history">
            <h2>{{i18n "mod_elections.history.title"}}</h2>
            <ul>
              {{#each this.history as |row|}}
                <li>
                  <LinkTo @query={{hash id=row.id}} @route="mod-elections">
                    {{row.label}}
                  </LinkTo>
                  {{#if (eq row.status "cancelled")}}
                    <span class="mod-elections-muted">{{i18n
                        "mod_elections.history.cancelled"
                      }}</span>
                  {{/if}}
                </li>
              {{/each}}
            </ul>
          </section>
        {{/if}}
      </ConditionalLoadingSpinner>
    </div>
  </template>
}
