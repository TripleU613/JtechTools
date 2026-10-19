import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { concat, fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import ConditionalLoadingSpinner from "discourse/components/conditional-loading-spinner";
import DButton from "discourse/components/d-button";
import type DialogService from "discourse/dialog-holder/services/dialog";
import avatar from "discourse/helpers/avatar";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { longDate } from "discourse/lib/formatter";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import ModElectionsResults from "discourse/plugins/jtech-tools/discourse/components/mod-elections-results";
import type {
  ModElectionCandidate,
  ModElectionResult,
  ModElectionStatus,
  ModElectionUser,
} from "discourse/plugins/jtech-tools/discourse/services/mod-elections";

const BASE = "/jtech-elections/admin";
const UNFINISHED: ModElectionStatus[] = [
  "scheduled",
  "nominating",
  "voting",
  "closed",
];

// ── Payloads (DiscourseModElections::Presenter admin_*) ─────────────────

type EditField =
  | "seats"
  | "nominations_open_at"
  | "voting_open_at"
  | "voting_close_at";

// The change form's fields, as the inputs hold them.
type EditForm = Record<EditField, string>;

interface AdminElectionRow {
  id: number;
  status: ModElectionStatus;
  seats: number;
  nominations_open_at: string;
  voting_open_at: string;
  voting_close_at: string;
  published_at: string | null;
}

interface AdminSeatHolder {
  id: number;
  user: ModElectionUser | null;
  seat_left_at: string | null;
  seat_left_reason: "stepped_down" | "removed" | null;
}

interface AdminSeats {
  election_id: number;
  seats: number;
  open: number;
  holders: AdminSeatHolder[];
}

interface AdminIndex {
  enabled: boolean;
  schedule: {
    months: number[];
    timezone: string;
    next_opening: string | null;
    seats: number;
    nomination_days: number;
    voting_days: number;
  };
  elections: AdminElectionRow[];
  seats: AdminSeats | null;
  sitting: ModElectionUser[];
}

interface AdminCandidate extends ModElectionCandidate {
  trust_level: number | null;
}

// A suspension or silence a moderator gave a candidate or a voter during
// the election.
interface ModeratorAction {
  action: "suspend" | "silence";
  at: string;
  by: ModElectionUser | null;
  user: ModElectionUser | null;
}

interface AdminElection extends AdminElectionRow {
  // No more candidates than seats when nominations closed: they stayed
  // open longer, then there was no Vote Week.
  nominations_extended: boolean;
  vote_skipped: boolean;
  // What can still change: the seats, and the dates still ahead.
  editable: EditField[];
  topic_id: number | null;
  // When the count was first previewed; ballots are fixed from then.
  previewed_at: string | null;
  moderator_actions: ModeratorAction[];
  candidates: AdminCandidate[];
  turnout: {
    voters: number;
    voters_weight: number;
    ballots: number;
    ballots_weight: number;
    voided: number;
  };
  result: ModElectionResult | null;
}

interface IpBallot {
  id: number;
  user: ModElectionUser | null;
  trust_level: number | null;
  weight: number;
  account_created_at: string | null;
  voided: boolean;
  void_reason: string | null;
}

interface IpGroup {
  ip: string;
  ballots: IpBallot[];
  candidates: ModElectionUser[];
}

interface PlanLeave extends ModElectionUser {
  strike: boolean;
  strikes: number;
  trust_level: number | null;
  // False for someone made a moderator after nominations opened: never on
  // this ballot, but publishing still ends their seat.
  on_ballot: boolean;
}

// A winner who can't take the seat any more; publishing waits until an
// admin takes them off the ballot.
interface PlanProblem {
  candidate_id: number;
  user: ModElectionUser | null;
  reason: "deleted" | "admin" | "suspended" | "silenced" | "inactive";
}

interface Preview {
  result: ModElectionResult;
  plan: {
    join: ModElectionUser[];
    stay: ModElectionUser[];
    leave: PlanLeave[];
    problems: PlanProblem[];
  };
}

// Asking for a reason inline: who it's for and what it's for.
interface ReasonTarget {
  kind: "disqualify" | "void";
  id: number;
}

const names = (users: ModElectionUser[]): string =>
  users.length
    ? users.map((u) => u.username).join(", ")
    : i18n("admin.mod_elections.preview.nobody");

// <input type="datetime-local"> wants local time without a zone.
const localInput = (date: Date): string => {
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(
    date.getDate()
  )}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
};

// The Mod elections tab: the schedule, the election in progress (end a
// phase early, take someone off the ballot, check for ballots cast from one
// address, preview and publish the count), the seats between elections, and
// starting an election by hand.
export default class ModElectionsAdmin extends Component {
  @service declare dialog: DialogService;

  @tracked index: AdminIndex | null = null;
  @tracked current: AdminElection | null = null;
  @tracked ipReport: IpGroup[] | null = null;
  @tracked preview: Preview | null = null;
  @tracked loading = true;
  @tracked busy = false;
  @tracked reasonFor: ReasonTarget | null = null;
  @tracked reason = "";

  // Changing the election under way: null until the form is open.
  @tracked edit: EditForm | null = null;

  @tracked newSeats = "";
  @tracked newNominations = localInput(new Date());
  @tracked newVoting = localInput(new Date(Date.now() + 7 * 864e5));
  @tracked newClose = localInput(new Date(Date.now() + 14 * 864e5));

  // The change form as it opened, so only what the admin changes is sent.
  editFrom: EditForm | null = null;

  pastUrl = (id: number): string => getURL(`/elections?id=${id}`);

  date = (value: string | null): string => (value ? longDate(value) : "");

  canEdit = (field: EditField): boolean =>
    !!this.current?.editable.includes(field);

  isAsking = (kind: string, id: number): boolean =>
    this.reasonFor?.kind === kind && this.reasonFor.id === id;

  planNames = (users: ModElectionUser[]): string => names(users);

  constructor(owner: Owner, args: object) {
    super(owner, args);
    this.load();
  }

  get scheduleLine(): string | null {
    const schedule = this.index?.schedule;
    if (!schedule) {
      return null;
    }
    if (!schedule.next_opening) {
      return i18n("admin.mod_elections.schedule.none");
    }
    return i18n("admin.mod_elections.schedule.next", {
      date: longDate(schedule.next_opening),
    });
  }

  get scheduleDetail(): string | null {
    const schedule = this.index?.schedule;
    return schedule
      ? i18n("admin.mod_elections.schedule.detail", {
          seats: schedule.seats,
          nomination_days: schedule.nomination_days,
          voting_days: schedule.voting_days,
          zone: schedule.timezone,
        })
      : null;
  }

  get phaseLine(): string | null {
    const e = this.current;
    if (!e) {
      return null;
    }
    const date =
      e.status === "scheduled"
        ? e.nominations_open_at
        : e.status === "nominating"
          ? e.voting_open_at
          : e.voting_close_at;
    const phase =
      e.status === "nominating" && e.nominations_extended
        ? "nominating_extended"
        : e.status === "closed" && e.vote_skipped
          ? "vote_skipped"
          : e.status;
    return i18n(`admin.mod_elections.current.phase.${phase}`, {
      date: longDate(date),
    });
  }

  get canEndPhase(): boolean {
    return ["scheduled", "nominating", "voting"].includes(
      this.current?.status || ""
    );
  }

  get isClosed(): boolean {
    return this.current?.status === "closed";
  }

  get ballotsFixed(): boolean {
    return !!this.current?.previewed_at;
  }

  get moderatorActions(): { at: string; text: string }[] {
    return (this.current?.moderator_actions || []).map((entry) => ({
      at: longDate(entry.at),
      text: i18n(`admin.mod_elections.moderator_actions.${entry.action}`, {
        by: entry.by?.username || "?",
        username:
          entry.user?.username || i18n("mod_elections.candidates.deleted"),
      }),
    }));
  }

  get problems(): { candidateId: number; text: string }[] {
    return (this.preview?.plan.problems || []).map((problem) => ({
      candidateId: problem.candidate_id,
      text: i18n(`admin.mod_elections.preview.problems.${problem.reason}`, {
        username:
          problem.user?.username || i18n("mod_elections.candidates.deleted"),
      }),
    }));
  }

  get cannotPublish(): boolean {
    return this.busy || this.problems.length > 0;
  }

  get past(): AdminElectionRow[] {
    return (this.index?.elections || []).filter(
      (e) => !UNFINISHED.includes(e.status)
    );
  }

  get electionUrl(): string {
    return getURL("/elections");
  }

  @action
  async load() {
    this.loading = true;
    try {
      this.index = await ajax(`${BASE}.json`);
      const unfinished = this.index?.elections.find((e) =>
        UNFINISHED.includes(e.status)
      );
      this.current = unfinished
        ? await ajax(`${BASE}/elections/${unfinished.id}.json`)
        : null;
      this.preview = null;
      this.ipReport = null;
      if (this.current?.status === "closed") {
        await this.checkIps();
      }
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.loading = false;
    }
  }

  async run(task: () => Promise<unknown>) {
    this.busy = true;
    try {
      await task();
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.busy = false;
    }
  }

  confirmThen(message: string, task: () => Promise<unknown>) {
    this.dialog.yesNoConfirm({ message, didConfirm: () => this.run(task) });
  }

  @action
  endPhase() {
    const election = this.current!;
    this.confirmThen(
      i18n("admin.mod_elections.current.end_phase_confirm"),
      async () => {
        await ajax(`${BASE}/elections/${election.id}/end-phase.json`, {
          type: "POST",
        });
        await this.load();
      }
    );
  }

  @action
  cancelElection() {
    const election = this.current!;
    this.confirmThen(
      i18n("admin.mod_elections.current.cancel_confirm"),
      async () => {
        await ajax(`${BASE}/elections/${election.id}/cancel.json`, {
          type: "POST",
        });
        await this.load();
      }
    );
  }

  @action
  askReason(kind: ReasonTarget["kind"], id: number) {
    this.reasonFor = { kind, id };
    this.reason = "";
  }

  @action
  cancelReason() {
    this.reasonFor = null;
  }

  @action
  setReason(event: Event) {
    this.reason = (event.target as HTMLInputElement).value;
  }

  @action
  submitReason() {
    const target = this.reasonFor;
    const election = this.current;
    if (!target || !election) {
      return;
    }
    this.run(async () => {
      if (target.kind === "disqualify") {
        this.current = await ajax(
          `${BASE}/elections/${election.id}/candidates/${target.id}/disqualify.json`,
          { type: "POST", data: { reason: this.reason } }
        );
      } else {
        const data = await ajax(
          `${BASE}/elections/${election.id}/ballots/${target.id}/void.json`,
          { type: "POST", data: { reason: this.reason } }
        );
        this.ipReport = data.ip_report;
      }
      // The count changed: a preview from before would publish a different
      // result than it shows.
      this.preview = null;
      this.reasonFor = null;
    });
  }

  @action
  reinstate(candidate: AdminCandidate) {
    const election = this.current!;
    this.run(async () => {
      this.current = await ajax(
        `${BASE}/elections/${election.id}/candidates/${candidate.id}/reinstate.json`,
        { type: "POST" }
      );
      this.preview = null;
    });
  }

  @action
  async checkIps() {
    const election = this.current;
    if (!election) {
      return;
    }
    const data = await ajax(`${BASE}/elections/${election.id}/ip-report.json`);
    this.ipReport = data.ip_report;
  }

  @action
  restoreBallot(ballot: IpBallot) {
    const election = this.current!;
    this.run(async () => {
      const data = await ajax(
        `${BASE}/elections/${election.id}/ballots/${ballot.id}/restore.json`,
        { type: "POST" }
      );
      this.ipReport = data.ip_report;
      this.preview = null;
    });
  }

  // The first preview fixes the ballots (the server refuses to set any
  // aside after it); the answer carries the election to show that.
  @action
  loadPreview() {
    const election = this.current!;
    this.run(async () => {
      const data: Preview & { election: AdminElection } = await ajax(
        `${BASE}/elections/${election.id}/preview.json`,
        { type: "POST" }
      );
      this.preview = { result: data.result, plan: data.plan };
      this.current = data.election;
    });
  }

  @action
  publish() {
    const election = this.current!;
    this.confirmThen(
      i18n("admin.mod_elections.preview.publish_confirm"),
      async () => {
        await ajax(`${BASE}/elections/${election.id}/publish.json`, {
          type: "POST",
        });
        await this.load();
      }
    );
  }

  @action
  vacate(holder: AdminSeatHolder, reason: "stepped_down" | "removed") {
    const key = reason === "removed" ? "remove_confirm" : "step_down_confirm";
    this.confirmThen(
      i18n(`admin.mod_elections.seats.${key}`, {
        username: holder.user?.username,
      }),
      async () => {
        await ajax(`${BASE}/seats/${holder.id}/vacate.json`, {
          type: "POST",
          data: { reason },
        });
        await this.load();
      }
    );
  }

  @action
  countback() {
    this.run(async () => {
      const data = await ajax(`${BASE}/seats/countback.json`);
      if (!data.replacement) {
        this.dialog.alert(i18n("admin.mod_elections.seats.no_replacement"));
        return;
      }
      this.confirmThen(
        i18n("admin.mod_elections.seats.countback_confirm", {
          username: data.replacement.username,
        }),
        async () => {
          await ajax(`${BASE}/seats/fill.json`, { type: "POST" });
          await this.load();
        }
      );
    });
  }

  @action
  startEdit() {
    const e = this.current!;
    this.editFrom = {
      seats: String(e.seats),
      nominations_open_at: localInput(new Date(e.nominations_open_at)),
      voting_open_at: localInput(new Date(e.voting_open_at)),
      voting_close_at: localInput(new Date(e.voting_close_at)),
    };
    this.edit = { ...this.editFrom };
  }

  @action
  cancelEdit() {
    this.edit = null;
  }

  @action
  setEdit(field: EditField, event: Event) {
    this.edit = {
      ...this.edit!,
      [field]: (event.target as HTMLInputElement).value,
    };
  }

  // Only what the admin changed goes, dates as exact moments: a date
  // shown to the minute and sent back unchanged would move it by seconds.
  @action
  saveEdit() {
    const election = this.current!;
    const form = this.edit!;
    const data: Partial<EditForm> = {};
    election.editable
      .filter((field) => form[field] !== this.editFrom![field])
      .forEach((field) => {
        data[field] =
          field === "seats" ? form.seats : new Date(form[field]).toISOString();
      });
    this.run(async () => {
      await ajax(`${BASE}/elections/${election.id}.json`, {
        type: "PUT",
        data,
      });
      this.edit = null;
      await this.load();
    });
  }

  @action
  setSeats(event: Event) {
    this.newSeats = (event.target as HTMLInputElement).value;
  }

  @action
  setNominations(event: Event) {
    this.newNominations = (event.target as HTMLInputElement).value;
  }

  @action
  setVoting(event: Event) {
    this.newVoting = (event.target as HTMLInputElement).value;
  }

  @action
  setClose(event: Event) {
    this.newClose = (event.target as HTMLInputElement).value;
  }

  @action
  createElection() {
    this.run(async () => {
      await ajax(`${BASE}/elections.json`, {
        type: "POST",
        data: {
          seats: this.newSeats || undefined,
          nominations_open_at: new Date(this.newNominations).toISOString(),
          voting_open_at: new Date(this.newVoting).toISOString(),
          voting_close_at: new Date(this.newClose).toISOString(),
        },
      });
      await this.load();
    });
  }

  <template>
    <div class="mod-elections-admin">
      <ConditionalLoadingSpinner @condition={{this.loading}}>
        {{#if this.index}}
          {{#unless this.index.enabled}}
            <p class="mod-elections-admin__off">{{i18n
                "admin.mod_elections.off"
              }}</p>
          {{/unless}}

          <section class="mod-elections-admin__card">
            <h3>{{i18n "admin.mod_elections.schedule.title"}}</h3>
            <p>{{this.scheduleLine}}</p>
            <p class="mod-elections-muted">{{this.scheduleDetail}}</p>
          </section>

          {{#if this.current}}
            <section
              class="mod-elections-admin__card mod-elections-admin__current"
            >
              <h3>
                {{i18n "admin.mod_elections.current.title"}}
                <span class="mod-elections-chip">{{i18n
                    (concat "mod_elections.status." this.current.status)
                  }}</span>
                <span
                  class="mod-elections-chip mod-elections-admin__seat-count"
                >{{i18n "mod_elections.seats" count=this.current.seats}}</span>
              </h3>
              <p>{{this.phaseLine}}</p>
              {{#if this.edit}}
                <div
                  class="mod-elections-admin__create mod-elections-admin__edit"
                >
                  {{#if (this.canEdit "seats")}}
                    <label>
                      {{i18n "admin.mod_elections.create.seats"}}
                      <input
                        class="mod-elections-admin__seats"
                        min="1"
                        type="number"
                        value={{this.edit.seats}}
                        {{on "input" (fn this.setEdit "seats")}}
                      />
                    </label>
                  {{/if}}
                  {{#if (this.canEdit "nominations_open_at")}}
                    <label>
                      {{i18n "admin.mod_elections.create.nominations_open_at"}}
                      <input
                        type="datetime-local"
                        value={{this.edit.nominations_open_at}}
                        {{on "input" (fn this.setEdit "nominations_open_at")}}
                      />
                    </label>
                  {{/if}}
                  {{#if (this.canEdit "voting_open_at")}}
                    <label>
                      {{i18n "admin.mod_elections.create.voting_open_at"}}
                      <input
                        type="datetime-local"
                        value={{this.edit.voting_open_at}}
                        {{on "input" (fn this.setEdit "voting_open_at")}}
                      />
                    </label>
                  {{/if}}
                  {{#if (this.canEdit "voting_close_at")}}
                    <label>
                      {{i18n "admin.mod_elections.create.voting_close_at"}}
                      <input
                        type="datetime-local"
                        value={{this.edit.voting_close_at}}
                        {{on "input" (fn this.setEdit "voting_close_at")}}
                      />
                    </label>
                  {{/if}}
                </div>
                <div class="mod-elections-actions">
                  <DButton
                    class="btn-primary mod-elections-admin__save-edit"
                    @action={{this.saveEdit}}
                    @disabled={{this.busy}}
                    @label="admin.mod_elections.current.edit_save"
                  />
                  <DButton
                    class="btn-flat"
                    @action={{this.cancelEdit}}
                    @label="admin.mod_elections.current.edit_cancel"
                  />
                </div>
              {{/if}}
              <div class="mod-elections-actions">
                {{#if this.current.editable.length}}
                  {{#unless this.edit}}
                    <DButton
                      class="btn-default mod-elections-admin__edit-button"
                      @action={{this.startEdit}}
                      @disabled={{this.busy}}
                      @icon="pencil"
                      @label="admin.mod_elections.current.edit"
                    />
                  {{/unless}}
                {{/if}}
                {{#if this.canEndPhase}}
                  <DButton
                    class="btn-default mod-elections-admin__end-phase"
                    @action={{this.endPhase}}
                    @disabled={{this.busy}}
                    @translatedLabel={{i18n
                      (concat
                        "admin.mod_elections.current.end_phase."
                        this.current.status
                      )
                    }}
                  />
                {{/if}}
                <DButton
                  class="btn-danger mod-elections-admin__cancel"
                  @action={{this.cancelElection}}
                  @disabled={{this.busy}}
                  @label="admin.mod_elections.current.cancel"
                />
                <a href={{this.electionUrl}}>{{i18n
                    "admin.mod_elections.current.open_page"
                  }}</a>
              </div>

              <h4>{{i18n "admin.mod_elections.turnout.title"}}</h4>
              <ul class="mod-elections-admin__turnout">
                <li>{{i18n
                    "admin.mod_elections.turnout.voters"
                    count=this.current.turnout.voters
                    weight=this.current.turnout.voters_weight
                  }}</li>
                <li>{{i18n
                    "admin.mod_elections.turnout.ballots"
                    count=this.current.turnout.ballots
                    weight=this.current.turnout.ballots_weight
                  }}</li>
                <li>{{i18n
                    "admin.mod_elections.turnout.voided"
                    count=this.current.turnout.voided
                  }}</li>
              </ul>

              <h4>{{i18n "admin.mod_elections.candidates.title"}}</h4>
              {{#if this.current.candidates.length}}
                <table class="mod-elections-admin__table">
                  <tbody>
                    {{#each this.current.candidates as |candidate|}}
                      <tr data-candidate-id={{candidate.id}}>
                        <td>
                          {{avatar candidate.user imageSize="tiny"}}
                          {{candidate.user.username}}
                          {{#if candidate.incumbent}}
                            <span class="mod-elections-chip">{{i18n
                                "admin.mod_elections.candidates.moderator"
                              }}</span>
                          {{/if}}
                        </td>
                        <td>{{i18n
                            "admin.mod_elections.candidates.trust_level"
                            level=candidate.trust_level
                          }}</td>
                        <td>
                          {{i18n
                            (concat
                              "admin.mod_elections.candidates.statuses."
                              candidate.status
                            )
                          }}
                          {{#if candidate.disqualified_reason}}
                            <div
                              class="mod-elections-muted"
                            >{{candidate.disqualified_reason}}</div>
                          {{/if}}
                        </td>
                        <td class="mod-elections-admin__row-actions">
                          {{#if (this.isAsking "disqualify" candidate.id)}}
                            <input
                              class="mod-elections-admin__reason"
                              placeholder={{i18n
                                "admin.mod_elections.candidates.disqualify_prompt"
                              }}
                              type="text"
                              value={{this.reason}}
                              {{on "input" this.setReason}}
                            />
                            <DButton
                              class="btn-danger btn-small"
                              @action={{this.submitReason}}
                              @disabled={{this.busy}}
                              @label="admin.mod_elections.candidates.disqualify"
                            />
                            <DButton
                              class="btn-flat btn-small"
                              @action={{this.cancelReason}}
                              @icon="xmark"
                            />
                          {{else if (eq candidate.status "disqualified")}}
                            <DButton
                              class="btn-default btn-small"
                              @action={{fn this.reinstate candidate}}
                              @disabled={{this.busy}}
                              @label="admin.mod_elections.candidates.reinstate"
                            />
                          {{else if (eq candidate.status "running")}}
                            <DButton
                              class="btn-default btn-small mod-elections-admin__disqualify"
                              @action={{fn
                                this.askReason
                                "disqualify"
                                candidate.id
                              }}
                              @label="admin.mod_elections.candidates.disqualify"
                            />
                          {{/if}}
                        </td>
                      </tr>
                    {{/each}}
                  </tbody>
                </table>
              {{else}}
                <p class="mod-elections-muted">{{i18n
                    "admin.mod_elections.candidates.none"
                  }}</p>
              {{/if}}

              {{#if this.moderatorActions.length}}
                <div class="mod-elections-admin__problems">
                  <p>{{i18n "admin.mod_elections.moderator_actions.title"}}</p>
                  <ul class="mod-elections-admin__moderator-actions">
                    {{#each this.moderatorActions as |entry|}}
                      <li>{{entry.text}}
                        <span
                          class="mod-elections-muted"
                        >{{entry.at}}</span></li>
                    {{/each}}
                  </ul>
                </div>
              {{/if}}

              {{#if this.isClosed}}
                <h4>{{i18n "admin.mod_elections.ip.title"}}</h4>
                {{#if this.ipReport.length}}
                  {{#each this.ipReport as |group|}}
                    <div class="mod-elections-admin__ip" data-ip={{group.ip}}>
                      <code>{{group.ip}}</code>
                      {{#if group.candidates.length}}
                        <span class="mod-elections-muted">{{i18n
                            "admin.mod_elections.ip.candidates"
                            names=(this.planNames group.candidates)
                          }}</span>
                      {{/if}}
                      <table class="mod-elections-admin__table">
                        <tbody>
                          {{#each group.ballots as |ballot|}}
                            <tr data-ballot-id={{ballot.id}}>
                              <td>
                                {{avatar ballot.user imageSize="tiny"}}
                                {{ballot.user.username}}
                              </td>
                              <td>{{i18n
                                  "admin.mod_elections.candidates.trust_level"
                                  level=ballot.weight
                                }}</td>
                              <td class="mod-elections-muted">{{i18n
                                  "admin.mod_elections.ip.joined"
                                  date=(this.date ballot.account_created_at)
                                }}</td>
                              <td class="mod-elections-admin__row-actions">
                                {{#if ballot.voided}}
                                  <span class="mod-elections-muted">{{i18n
                                      "admin.mod_elections.ip.voided"
                                      reason=ballot.void_reason
                                    }}</span>
                                  {{#unless this.ballotsFixed}}
                                    <DButton
                                      class="btn-default btn-small"
                                      @action={{fn this.restoreBallot ballot}}
                                      @disabled={{this.busy}}
                                      @label="admin.mod_elections.ip.restore"
                                    />
                                  {{/unless}}
                                {{else if this.ballotsFixed}}
                                  <span class="mod-elections-muted">{{i18n
                                      "admin.mod_elections.ip.counted"
                                    }}</span>
                                {{else if (this.isAsking "void" ballot.id)}}
                                  <input
                                    class="mod-elections-admin__reason"
                                    placeholder={{i18n
                                      "admin.mod_elections.ip.void_prompt"
                                    }}
                                    type="text"
                                    value={{this.reason}}
                                    {{on "input" this.setReason}}
                                  />
                                  <DButton
                                    class="btn-danger btn-small"
                                    @action={{this.submitReason}}
                                    @disabled={{this.busy}}
                                    @label="admin.mod_elections.ip.void"
                                  />
                                  <DButton
                                    class="btn-flat btn-small"
                                    @action={{this.cancelReason}}
                                    @icon="xmark"
                                  />
                                {{else}}
                                  <DButton
                                    class="btn-default btn-small mod-elections-admin__void"
                                    @action={{fn
                                      this.askReason
                                      "void"
                                      ballot.id
                                    }}
                                    @label="admin.mod_elections.ip.void"
                                  />
                                {{/if}}
                              </td>
                            </tr>
                          {{/each}}
                        </tbody>
                      </table>
                    </div>
                  {{/each}}
                {{else}}
                  <p class="mod-elections-muted">{{i18n
                      "admin.mod_elections.ip.none"
                    }}</p>
                {{/if}}

                <div class="mod-elections-actions">
                  <DButton
                    class="btn-default mod-elections-admin__preview"
                    @action={{this.loadPreview}}
                    @disabled={{this.busy}}
                    @icon="list-ol"
                    @label="admin.mod_elections.preview.button"
                  />
                  <span class="mod-elections-muted">{{if
                      this.ballotsFixed
                      (i18n "admin.mod_elections.preview.fixed")
                      (i18n "admin.mod_elections.preview.fixes")
                    }}</span>
                </div>

                {{#if this.preview}}
                  <ModElectionsResults @result={{this.preview.result}} />
                  {{#if this.problems.length}}
                    <div class="mod-elections-admin__problems" role="alert">
                      <p>{{i18n
                          "admin.mod_elections.preview.problems.title"
                        }}</p>
                      <ul>
                        {{#each this.problems as |problem|}}
                          <li
                            data-candidate-id={{problem.candidateId}}
                          >{{problem.text}}</li>
                        {{/each}}
                      </ul>
                    </div>
                  {{/if}}
                  <h4>{{i18n "admin.mod_elections.preview.title"}}</h4>
                  <dl class="mod-elections-admin__plan">
                    <dt>{{i18n "admin.mod_elections.preview.join"}}</dt>
                    <dd>{{this.planNames this.preview.plan.join}}</dd>
                    <dt>{{i18n "admin.mod_elections.preview.stay"}}</dt>
                    <dd>{{this.planNames this.preview.plan.stay}}</dd>
                    <dt>{{i18n "admin.mod_elections.preview.leave"}}</dt>
                    <dd>
                      {{#each this.preview.plan.leave as |row|}}
                        <div>
                          {{row.username}}
                          {{#if row.strike}}
                            <span class="mod-elections-chip">{{i18n
                                "admin.mod_elections.preview.strike"
                                count=row.strikes
                              }}</span>
                          {{/if}}
                          {{#if row.trust_level}}
                            <span class="mod-elections-muted">{{i18n
                                "admin.mod_elections.preview.trust_level"
                                level=row.trust_level
                              }}</span>
                          {{/if}}
                          {{#unless row.on_ballot}}
                            <span
                              class="mod-elections-chip mod-elections-admin__not-on-ballot"
                            >{{i18n
                                "admin.mod_elections.preview.not_on_ballot"
                              }}</span>
                          {{/unless}}
                        </div>
                      {{else}}
                        {{i18n "admin.mod_elections.preview.nobody"}}
                      {{/each}}
                    </dd>
                  </dl>
                  <div class="mod-elections-actions">
                    <DButton
                      class="btn-primary mod-elections-admin__publish"
                      @action={{this.publish}}
                      @disabled={{this.cannotPublish}}
                      @icon="check"
                      @label="admin.mod_elections.preview.publish"
                    />
                  </div>
                {{/if}}
              {{/if}}
            </section>
          {{else}}
            <section class="mod-elections-admin__card">
              <h3>{{i18n "admin.mod_elections.current.title"}}</h3>
              <p class="mod-elections-muted">{{i18n
                  "admin.mod_elections.current.none"
                }}</p>

              <h4>{{i18n "admin.mod_elections.create.title"}}</h4>
              <div class="mod-elections-admin__create">
                <label>
                  {{i18n "admin.mod_elections.create.seats"}}
                  <input
                    class="mod-elections-admin__seats"
                    min="1"
                    placeholder={{this.index.schedule.seats}}
                    type="number"
                    value={{this.newSeats}}
                    {{on "input" this.setSeats}}
                  />
                </label>
                <label>
                  {{i18n "admin.mod_elections.create.nominations_open_at"}}
                  <input
                    type="datetime-local"
                    value={{this.newNominations}}
                    {{on "input" this.setNominations}}
                  />
                </label>
                <label>
                  {{i18n "admin.mod_elections.create.voting_open_at"}}
                  <input
                    type="datetime-local"
                    value={{this.newVoting}}
                    {{on "input" this.setVoting}}
                  />
                </label>
                <label>
                  {{i18n "admin.mod_elections.create.voting_close_at"}}
                  <input
                    type="datetime-local"
                    value={{this.newClose}}
                    {{on "input" this.setClose}}
                  />
                </label>
              </div>
              <div class="mod-elections-actions">
                <DButton
                  class="btn-primary mod-elections-admin__start"
                  @action={{this.createElection}}
                  @disabled={{this.busy}}
                  @label="admin.mod_elections.create.submit"
                />
              </div>
            </section>
          {{/if}}

          <section class="mod-elections-admin__card">
            <h3>{{i18n "admin.mod_elections.seats.title"}}</h3>
            {{#if this.index.seats}}
              <ul class="mod-elections-admin__seats-list">
                {{#each this.index.seats.holders as |holder|}}
                  <li data-candidate-id={{holder.id}}>
                    {{avatar holder.user imageSize="tiny"}}
                    {{holder.user.username}}
                    {{#if holder.seat_left_reason}}
                      <span class="mod-elections-muted">{{i18n
                          (concat
                            "admin.mod_elections.seats.left."
                            holder.seat_left_reason
                          )
                        }}</span>
                    {{else}}
                      <DButton
                        class="btn-default btn-small"
                        @action={{fn this.vacate holder "stepped_down"}}
                        @disabled={{this.busy}}
                        @label="admin.mod_elections.seats.step_down"
                      />
                      <DButton
                        class="btn-danger btn-small mod-elections-admin__remove"
                        @action={{fn this.vacate holder "removed"}}
                        @disabled={{this.busy}}
                        @label="admin.mod_elections.seats.remove"
                      />
                    {{/if}}
                  </li>
                {{/each}}
              </ul>
              {{#if this.index.seats.open}}
                <p>{{i18n
                    "admin.mod_elections.seats.open"
                    count=this.index.seats.open
                  }}</p>
                <DButton
                  class="btn-default mod-elections-admin__countback"
                  @action={{this.countback}}
                  @disabled={{this.busy}}
                  @label="admin.mod_elections.seats.countback"
                />
              {{/if}}
            {{else}}
              <p class="mod-elections-muted">{{i18n
                  "admin.mod_elections.seats.none"
                }}</p>
            {{/if}}

            <h4>{{i18n "admin.mod_elections.sitting.title"}}</h4>
            <p>{{this.planNames this.index.sitting}}</p>
          </section>

          {{#if this.past.length}}
            <section class="mod-elections-admin__card">
              <h3>{{i18n "admin.mod_elections.history.title"}}</h3>
              <ul>
                {{#each this.past as |row|}}
                  <li>
                    <a href={{this.pastUrl row.id}}>{{this.date
                        row.nominations_open_at
                      }}</a>
                    {{#if row.published_at}}
                      <span class="mod-elections-muted">{{i18n
                          "admin.mod_elections.history.published"
                          date=(this.date row.published_at)
                        }}</span>
                    {{/if}}
                    <span class="mod-elections-muted">{{i18n
                        (concat "mod_elections.status." row.status)
                      }}</span>
                  </li>
                {{/each}}
              </ul>
            </section>
          {{/if}}
        {{/if}}
      </ConditionalLoadingSpinner>
    </div>
  </template>
}
