import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import type Owner from "@ember/owner";
import { service } from "@ember/service";
import { eq } from "truth-helpers";
import DButton from "discourse/components/d-button";
import type DialogService from "discourse/dialog-holder/services/dialog";
import ageWithTooltip from "discourse/helpers/age-with-tooltip";
import avatar from "discourse/helpers/avatar";
import icon from "discourse/helpers/d-icon";
import { popupAjaxError } from "discourse/lib/ajax-error";
import type Site from "discourse/models/site";
import { i18n } from "discourse-i18n";
import ModElectionsService, {
  ModElection,
  ModElectionCandidate,
  ModElectionMe,
  ModElectionPage,
  ModElectionsCurrentUser,
} from "../services/mod-elections";

interface ModElectionsBallotSignature {
  Args: {
    election: ModElection;
    me: ModElectionMe;
    onChange: (page: ModElectionPage) => void;
  };
}

const place = (index: number): number => index + 1;

const nameOf = (candidate: ModElectionCandidate): string =>
  candidate.user?.username || "?";

// Vote Week: build a ranking from the candidates, best first, and save it.
// Buttons do everything, so it works the same with a mouse, a finger and a
// keyboard; on desktop candidates can be dragged into place as well.
export default class ModElectionsBallot extends Component<ModElectionsBallotSignature> {
  @service declare modElections: ModElectionsService;
  @service declare dialog: DialogService;
  @service declare currentUser: ModElectionsCurrentUser;
  @service declare site: Site;

  @tracked ranking: number[];
  @tracked saving = false;
  // Read out after each change, for anyone using a screen reader.
  @tracked announcement = "";
  // Dragging: who, and where they'd land (an index in the ranking; its
  // length means the end).
  @tracked dragging: number | null = null;
  @tracked dropAt: number | null = null;

  isSelf = (candidate: ModElectionCandidate): boolean =>
    candidate.user?.id === this.currentUser?.id;

  isLast = (index: number): boolean => index === this.ranking.length - 1;

  isDropBefore = (index: number): boolean => this.dropAt === index;

  // "Move chaim up" rather than three buttons all called "Move up".
  label = (key: string, candidate: ModElectionCandidate): string =>
    i18n(`mod_elections.ballot.aria.${key}`, { username: nameOf(candidate) });

  constructor(owner: Owner, args: ModElectionsBallotSignature["Args"]) {
    super(owner, args);
    this.ranking = this.savedRanking;
  }

  get running(): ModElectionCandidate[] {
    return this.args.election.candidates.filter((c) => c.status === "running");
  }

  get byId(): Map<number, ModElectionCandidate> {
    return new Map(this.running.map((c) => [c.id, c]));
  }

  // The saved ballot, minus anyone taken off since.
  get savedRanking(): number[] {
    return (this.args.me.ballot?.ranking || []).filter((id) =>
      this.byId.has(id)
    );
  }

  get ranked(): ModElectionCandidate[] {
    const byId = this.byId;
    return this.ranking
      .map((id) => byId.get(id))
      .filter((c): c is ModElectionCandidate => !!c);
  }

  get unranked(): ModElectionCandidate[] {
    return this.running.filter((c) => !this.ranking.includes(c.id));
  }

  get dirty(): boolean {
    return this.ranking.join(",") !== this.savedRanking.join(",");
  }

  get cannotSave(): boolean {
    return !this.dirty || this.ranking.length === 0;
  }

  get voided(): boolean {
    return !!this.args.me.ballot?.voided;
  }

  get canDrag(): boolean {
    return this.site.desktopView;
  }

  get dropAtEnd(): boolean {
    return this.dropAt === this.ranking.length;
  }

  announce(key: string, candidate: ModElectionCandidate) {
    this.announcement = i18n(`mod_elections.ballot.announce.${key}`, {
      username: nameOf(candidate),
      place: this.ranking.indexOf(candidate.id) + 1,
    });
  }

  @action
  add(candidate: ModElectionCandidate) {
    this.ranking = [...this.ranking, candidate.id];
    this.announce("ranked", candidate);
  }

  @action
  remove(candidate: ModElectionCandidate) {
    this.ranking = this.ranking.filter((id) => id !== candidate.id);
    this.announce("removed", candidate);
  }

  @action
  move(candidate: ModElectionCandidate, by: number) {
    const from = this.ranking.indexOf(candidate.id);
    const to = from + by;
    if (from < 0 || to < 0 || to >= this.ranking.length) {
      return;
    }
    const next = [...this.ranking];
    next.splice(from, 1);
    next.splice(to, 0, candidate.id);
    this.ranking = next;
    this.announce("moved", candidate);
  }

  // ── Dragging (desktop) ──────────────────────────────────────────────

  @action
  dragStart(candidate: ModElectionCandidate, event: DragEvent) {
    this.dragging = candidate.id;
    if (event.dataTransfer) {
      event.dataTransfer.effectAllowed = "move";
      event.dataTransfer.setData("text/plain", nameOf(candidate));
    }
  }

  // Over a ranked row: land before it, or after it in its lower half.
  @action
  dragOverRow(index: number, event: DragEvent) {
    if (this.dragging === null) {
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    const row = event.currentTarget as HTMLElement;
    const box = row.getBoundingClientRect();
    this.dropAt = event.clientY > box.top + box.height / 2 ? index + 1 : index;
  }

  // Over the ranking but no row (the gap below them, or the empty list).
  @action
  dragOverRanking(event: DragEvent) {
    if (this.dragging === null) {
      return;
    }
    event.preventDefault();
    if (this.dropAt === null) {
      this.dropAt = this.ranking.length;
    }
  }

  @action
  dragOverPool(event: DragEvent) {
    if (this.dragging !== null && this.ranking.includes(this.dragging)) {
      event.preventDefault();
      this.dropAt = null;
    }
  }

  @action
  dropOnRanking(event: DragEvent) {
    event.preventDefault();
    const id = this.dragging;
    const at = this.dropAt ?? this.ranking.length;
    this.dragEnd();
    const candidate = id === null ? undefined : this.byId.get(id);
    if (!candidate || this.isSelf(candidate)) {
      return;
    }
    const from = this.ranking.indexOf(candidate.id);
    const next = this.ranking.filter((x) => x !== candidate.id);
    next.splice(from >= 0 && from < at ? at - 1 : at, 0, candidate.id);
    this.ranking = next;
    this.announce(from >= 0 ? "moved" : "ranked", candidate);
  }

  @action
  dropOnPool(event: DragEvent) {
    event.preventDefault();
    const candidate =
      this.dragging === null ? undefined : this.byId.get(this.dragging);
    this.dragEnd();
    if (candidate && this.ranking.includes(candidate.id)) {
      this.remove(candidate);
    }
  }

  @action
  dragLeaveRanking(event: DragEvent) {
    const list = event.currentTarget as HTMLElement;
    if (!list.contains(event.relatedTarget as Node | null)) {
      this.dropAt = null;
    }
  }

  @action
  dragEnd() {
    this.dragging = null;
    this.dropAt = null;
  }

  @action
  async save() {
    this.saving = true;
    try {
      this.args.onChange(
        await this.modElections.vote(this.args.election.id, this.ranking)
      );
    } catch (e) {
      popupAjaxError(e);
    } finally {
      this.saving = false;
    }
  }

  @action
  clear() {
    this.dialog.yesNoConfirm({
      message: i18n("mod_elections.ballot.clear_confirm"),
      didConfirm: async () => {
        try {
          const page = await this.modElections.clearBallot(
            this.args.election.id
          );
          this.ranking = [];
          this.args.onChange(page);
        } catch (e) {
          popupAjaxError(e);
        }
      },
    });
  }

  <template>
    <section class="mod-elections-panel mod-elections-ballot">
      <header class="mod-elections-ballot__head">
        <h2>{{i18n "mod_elections.ballot.title"}}</h2>
        {{#if @me.weight}}
          <span class="mod-elections-chip">{{i18n
              "mod_elections.ballot.weight"
              count=@me.weight
            }}</span>
        {{/if}}
      </header>

      {{#if this.voided}}
        <p class="mod-elections-candidate__flag">{{i18n
            "mod_elections.ballot.voided"
            reason=@me.ballot.void_reason
          }}</p>
      {{else}}
        <p class="mod-elections-muted">
          {{i18n "mod_elections.ballot.hint"}}
          {{#if this.canDrag}}
            {{i18n "mod_elections.ballot.drag_hint"}}
          {{/if}}
        </p>

        <div class="mod-elections-ballot__columns">
          <div class="mod-elections-ballot__column">
            <h3>{{i18n "mod_elections.ballot.your_ranking"}}</h3>
            <div
              class="mod-elections-ballot__dropzone
                {{if this.dragging 'is-dragging'}}
                {{if this.dropAtEnd 'is-drop-end'}}"
              {{on "dragover" this.dragOverRanking}}
              {{on "dragleave" this.dragLeaveRanking}}
              {{on "drop" this.dropOnRanking}}
            >
              {{#if this.ranked.length}}
                <ol
                  class="mod-elections-ballot__list mod-elections-ballot__ranking"
                >
                  {{#each this.ranked as |candidate index|}}
                    <li
                      class="mod-elections-ballot__row
                        {{if (this.isDropBefore index) 'is-drop-before'}}
                        {{if (eq this.dragging candidate.id) 'is-dragged'}}"
                      data-candidate-id={{candidate.id}}
                      draggable={{if this.canDrag "true"}}
                      {{on "dragstart" (fn this.dragStart candidate)}}
                      {{on "dragover" (fn this.dragOverRow index)}}
                      {{on "dragend" this.dragEnd}}
                    >
                      <span class="mod-elections-ballot__place">{{place
                          index
                        }}</span>
                      {{avatar candidate.user imageSize="small"}}
                      <span
                        class="mod-elections-ballot__name"
                      >{{candidate.user.username}}</span>
                      <span class="mod-elections-ballot__controls">
                        <DButton
                          class="btn-flat btn-small mod-elections-ballot__up"
                          @action={{fn this.move candidate -1}}
                          @disabled={{eq index 0}}
                          @icon="arrow-up"
                          @title="mod_elections.ballot.move_up"
                          @translatedAriaLabel={{this.label
                            "move_up"
                            candidate
                          }}
                        />
                        <DButton
                          class="btn-flat btn-small mod-elections-ballot__down"
                          @action={{fn this.move candidate 1}}
                          @disabled={{this.isLast index}}
                          @icon="arrow-down"
                          @title="mod_elections.ballot.move_down"
                          @translatedAriaLabel={{this.label
                            "move_down"
                            candidate
                          }}
                        />
                        <DButton
                          class="btn-flat btn-small mod-elections-ballot__remove"
                          @action={{fn this.remove candidate}}
                          @icon="xmark"
                          @title="mod_elections.ballot.remove"
                          @translatedAriaLabel={{this.label "remove" candidate}}
                        />
                      </span>
                    </li>
                  {{/each}}
                </ol>
              {{else}}
                <p class="mod-elections-ballot__empty">{{i18n
                    "mod_elections.ballot.empty_ranking"
                  }}</p>
              {{/if}}
            </div>
          </div>

          <div class="mod-elections-ballot__column">
            <h3>{{i18n "mod_elections.ballot.candidates"}}</h3>
            <ul
              class="mod-elections-ballot__list mod-elections-ballot__pool"
              {{on "dragover" this.dragOverPool}}
              {{on "drop" this.dropOnPool}}
            >
              {{#each this.unranked as |candidate|}}
                <li
                  class="mod-elections-ballot__row
                    {{if (eq this.dragging candidate.id) 'is-dragged'}}"
                  data-candidate-id={{candidate.id}}
                  draggable={{if
                    this.canDrag
                    (if (this.isSelf candidate) "false" "true")
                  }}
                  {{on "dragstart" (fn this.dragStart candidate)}}
                  {{on "dragend" this.dragEnd}}
                >
                  {{avatar candidate.user imageSize="small"}}
                  <div class="mod-elections-ballot__who">
                    <span class="mod-elections-ballot__name">
                      {{candidate.user.username}}
                      {{#if candidate.incumbent}}
                        <span
                          class="mod-elections-ballot__mod"
                          title={{i18n "mod_elections.candidates.moderator"}}
                        >{{icon "shield-halved"}}</span>
                      {{/if}}
                    </span>
                    {{#if candidate.statement}}
                      <details class="mod-elections-ballot__statement">
                        <summary>{{i18n
                            "mod_elections.ballot.read_statement"
                          }}</summary>
                        <p>{{candidate.statement}}</p>
                      </details>
                    {{/if}}
                  </div>
                  {{#if (this.isSelf candidate)}}
                    <span class="mod-elections-muted">{{i18n
                        "mod_elections.ballot.self"
                      }}</span>
                  {{else}}
                    <DButton
                      class="btn-default btn-small mod-elections-ballot__add"
                      @action={{fn this.add candidate}}
                      @icon="plus"
                      @label="mod_elections.ballot.add"
                      @translatedAriaLabel={{this.label "add" candidate}}
                    />
                  {{/if}}
                </li>
              {{else}}
                <li class="mod-elections-ballot__empty">{{i18n
                    "mod_elections.ballot.all_ranked"
                  }}</li>
              {{/each}}
            </ul>
          </div>
        </div>

        <footer class="mod-elections-ballot__foot">
          <DButton
            class="btn-primary mod-elections-ballot__save"
            @action={{this.save}}
            @disabled={{this.cannotSave}}
            @icon="check-to-slot"
            @isLoading={{this.saving}}
            @label="mod_elections.ballot.save"
          />
          <span class="mod-elections-muted mod-elections-ballot__state">
            {{#if this.dirty}}
              {{i18n "mod_elections.ballot.changed"}}
            {{else if @me.ballot}}
              {{icon "check"}}
              {{i18n "mod_elections.ballot.saved"}}
              {{ageWithTooltip @me.ballot.updated_at}}
            {{else}}
              {{i18n "mod_elections.ballot.not_saved"}}
            {{/if}}
          </span>
          {{#if @me.ballot}}
            <DButton
              class="btn-flat mod-elections-ballot__clear"
              @action={{this.clear}}
              @label="mod_elections.ballot.clear"
            />
          {{/if}}
        </footer>
        <p
          aria-live="polite"
          class="sr-only mod-elections-ballot__announce"
        >{{this.announcement}}</p>
      {{/if}}
    </section>
  </template>
}
