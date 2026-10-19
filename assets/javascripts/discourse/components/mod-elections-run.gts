import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import type DialogService from "discourse/dialog-holder/services/dialog";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { i18n } from "discourse-i18n";
import ModElectionsService, {
  ModElection,
  ModElectionLimits,
  ModElectionMe,
  ModElectionPage,
} from "../services/mod-elections.ts";

interface ModElectionsRunSignature {
  Args: {
    election: ModElection;
    me: ModElectionMe;
    limits: ModElectionLimits;
    onChange: (page: ModElectionPage) => void;
  };
}

// Nominations: run, change what you wrote, or drop out. Someone who can't
// run sees why.
export default class ModElectionsRun extends Component<ModElectionsRunSignature> {
  @service declare modElections: ModElectionsService;
  @service declare dialog: DialogService;

  @tracked editing = false;
  @tracked statement = "";
  @tracked saving = false;

  get candidacy() {
    const candidate = this.args.me.candidate;
    return candidate?.status === "running" ? candidate : null;
  }

  get maxLength(): number {
    return this.args.limits.statement_max_length;
  }

  get canRun(): boolean {
    return !this.candidacy && !this.args.me.run_blocked;
  }

  // Why not, in words. "already_running" never shows: the candidacy does.
  get blockedMessage(): string | null {
    const reason = this.args.me.run_blocked;
    if (!reason || reason === "already_running") {
      return null;
    }
    const limits = this.args.limits;
    return i18n(`mod_elections.blocked.${reason}`, {
      level: limits.candidate_min_trust_level,
      days:
        reason === "record"
          ? limits.candidate_clean_record_days
          : limits.candidate_min_account_age_days,
    });
  }

  get counter(): string {
    return i18n("mod_elections.run.counter", {
      count: this.statement.length,
      max: this.maxLength,
    });
  }

  get tooLong(): boolean {
    return this.statement.length > this.maxLength;
  }

  @action
  start() {
    this.statement = this.candidacy?.statement || "";
    this.editing = true;
  }

  @action
  cancel() {
    this.editing = false;
  }

  @action
  setStatement(event: Event) {
    this.statement = (event.target as HTMLTextAreaElement).value;
  }

  @action
  async submit() {
    this.saving = true;
    try {
      const page = this.candidacy
        ? await this.modElections.updateStatement(
            this.args.election.id,
            this.statement
          )
        : await this.modElections.run(this.args.election.id, this.statement);
      this.editing = false;
      this.args.onChange(page);
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.saving = false;
    }
  }

  @action
  withdraw() {
    this.dialog.yesNoConfirm({
      message: i18n("mod_elections.run.withdraw_confirm"),
      didConfirm: async () => {
        try {
          this.args.onChange(
            await this.modElections.withdraw(this.args.election.id)
          );
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  <template>
    <section class="mod-elections-panel mod-elections-run">
      {{#if this.editing}}
        <form class="mod-elections-run__form">
          <h2>{{i18n "mod_elections.run.title"}}</h2>
          {{#if this.maxLength}}
            <label
              class="mod-elections-run__label"
              for="mod-elections-statement"
            >{{i18n "mod_elections.run.statement_label"}}</label>
            <textarea
              class="mod-elections-run__statement"
              id="mod-elections-statement"
              placeholder={{i18n "mod_elections.run.statement_placeholder"}}
              rows="5"
              value={{this.statement}}
              {{on "input" this.setStatement}}
            ></textarea>
            <div
              class="mod-elections-run__counter
                {{if this.tooLong 'mod-elections-run__counter--over'}}"
            >{{this.counter}}</div>
          {{/if}}
          <div class="mod-elections-actions">
            <DButton
              class="btn-primary mod-elections-run__submit"
              @action={{this.submit}}
              @disabled={{this.tooLong}}
              @isLoading={{this.saving}}
              @label={{if
                this.candidacy
                "mod_elections.run.save"
                "mod_elections.run.submit"
              }}
            />
            <DButton
              class="btn-flat"
              @action={{this.cancel}}
              @label="mod_elections.run.cancel"
            />
          </div>
        </form>
      {{else if this.candidacy}}
        <div class="mod-elections-run__status">
          <p><strong>{{if
                this.candidacy.incumbent
                (i18n "mod_elections.run.running_incumbent")
                (i18n "mod_elections.run.running")
              }}</strong></p>
          {{#if this.candidacy.statement}}
            <p
              class="mod-elections-candidate__statement"
            >{{this.candidacy.statement}}</p>
          {{/if}}
        </div>
        <div class="mod-elections-actions">
          {{#if this.maxLength}}
            <DButton
              class="btn-default mod-elections-run__edit"
              @action={{this.start}}
              @icon="pencil"
              @label="mod_elections.run.edit"
            />
          {{/if}}
          <DButton
            class="btn-flat btn-danger mod-elections-run__withdraw"
            @action={{this.withdraw}}
            @label="mod_elections.run.withdraw"
          />
        </div>
      {{else if this.canRun}}
        <DButton
          class="btn-primary mod-elections-run__start"
          @action={{this.start}}
          @icon="check-to-slot"
          @label="mod_elections.run.button"
        />
      {{else if this.blockedMessage}}
        <p class="mod-elections-muted">{{this.blockedMessage}}</p>
      {{/if}}
    </section>
  </template>
}
