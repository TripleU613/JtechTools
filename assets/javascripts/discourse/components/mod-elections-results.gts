import Component from "@glimmer/component";
import { htmlSafe } from "@ember/template";
import avatar from "discourse/helpers/avatar";
import icon from "discourse/helpers/d-icon";
import getURL from "discourse/lib/get-url";
import { i18n } from "discourse-i18n";
import type {
  ModElectionCandidate,
  ModElectionResult,
  ModElectionResultCandidate,
  ModElectionStage,
  ModElectionTurnout,
} from "../services/mod-elections";

interface ModElectionsResultsSignature {
  Args: {
    result: ModElectionResult;
    turnout?: ModElectionTurnout | null;
    // The election's candidates now, for seats left since the count.
    candidates?: ModElectionCandidate[];
  };
}

interface ResultCell {
  value: string;
  elected: boolean;
  out: boolean;
  // How far toward the votes needed, as a bar under the number.
  bar: ReturnType<typeof htmlSafe> | null;
}

interface ResultRow {
  candidate: ModElectionResultCandidate;
  elected: boolean;
  cells: ResultCell[];
}

interface StageColumn {
  number: number;
  label: string;
}

const profileUrl = (username: string | null): string =>
  getURL(`/u/${username || ""}`);

// Rounded for reading; the server counts exactly.
const formatVotes = (value: number): string =>
  value.toLocaleString(undefined, { maximumFractionDigits: 2 });

// Winners, turnout, and the count stage by stage, so anyone can follow how
// each seat was won.
export default class ModElectionsResults extends Component<ModElectionsResultsSignature> {
  get people(): Map<number, ModElectionResultCandidate> {
    return new Map(this.args.result.candidates.map((c) => [c.id, c]));
  }

  // In the order they were elected, which is the order a countback skips
  // them in.
  get winners(): (ModElectionResultCandidate & { note: string | null })[] {
    const now = new Map((this.args.candidates || []).map((c) => [c.id, c]));
    return this.args.result.elected
      .map((id) => this.people.get(id))
      .filter((c): c is ModElectionResultCandidate => !!c)
      .map((c) => {
        const left = now.get(c.id)?.seat_left_reason;
        return {
          ...c,
          note: left ? i18n(`mod_elections.results.left.${left}`) : null,
        };
      });
  }

  get countbacks(): string[] {
    return (this.args.result.countbacks || []).map((row) =>
      i18n("mod_elections.results.countback", {
        username: this.name(row.candidate),
      })
    );
  }

  get ballotsLine(): string {
    const ballots = i18n("mod_elections.results.ballots", {
      count: this.args.result.ballots,
    });
    const voters = this.args.turnout?.voters;
    if (!voters) {
      return ballots;
    }
    const percent = Math.round((this.args.result.ballots / voters) * 100);
    return `${ballots} · ${i18n("mod_elections.results.of_voters", {
      percent,
      voters,
    })}`;
  }

  get quotaLine(): string {
    return i18n("mod_elections.results.quota", {
      quota: formatVotes(this.args.result.quota),
    });
  }

  get columns(): StageColumn[] {
    return this.args.result.stages.map((stage) => ({
      number: stage.number,
      label: this.stageLabel(stage),
    }));
  }

  // Winners first in the order they were elected, then everyone else by
  // how far they got.
  get rows(): ResultRow[] {
    const stages = this.args.result.stages;
    const elected = this.args.result.elected;
    const quota = this.args.result.quota;
    const outAt = new Map<number, number>();
    const electedAt = new Map<number, number>();
    stages.forEach((stage) => {
      stage.excluded.forEach((id) => outAt.set(id, stage.number));
      stage.elected.forEach((id) => electedAt.set(id, stage.number));
    });

    const reach = (id: number): number[] => {
      const last = outAt.get(id) ?? stages.length + 1;
      return [
        -last,
        -(stages[Math.max(last - 2, 0)]?.tallies[String(id)] || 0),
      ];
    };

    const others = this.args.result.candidates
      .filter((c) => !elected.includes(c.id))
      .sort((a, b) => {
        const [ra, va] = reach(a.id);
        const [rb, vb] = reach(b.id);
        return ra - rb || va - vb;
      });
    const order = [
      ...elected
        .map((id) => this.people.get(id))
        .filter((c): c is ModElectionResultCandidate => !!c),
      ...others,
    ];

    return order.map((candidate) => ({
      candidate,
      elected: elected.includes(candidate.id),
      cells: stages.map((stage) => {
        const out = (outAt.get(candidate.id) ?? Infinity) <= stage.number;
        const votes = stage.tallies[String(candidate.id)] || 0;
        const share = quota > 0 ? Math.min(votes / quota, 1) : 0;
        return {
          value: out ? "—" : formatVotes(votes),
          elected: electedAt.get(candidate.id) === stage.number,
          out,
          bar: out ? null : htmlSafe(`width:${Math.round(share * 100)}%`),
        };
      }),
    }));
  }

  get exhaustedCells(): string[] {
    return this.args.result.stages.map((stage) => formatVotes(stage.exhausted));
  }

  // Every tie the count broke, where, and how.
  get ties(): string[] {
    const seed = this.args.result.seed;
    return this.args.result.stages.flatMap((stage) =>
      stage.ties.map((tie) =>
        i18n(`mod_elections.results.ties.${tie.purpose}_${tie.method}`, {
          stage: stage.number,
          names: this.names(tie.among),
          chosen: this.name(tie.chosen),
          decided_at: tie.decided_at ?? "",
          seed,
        })
      )
    );
  }

  name(id: number | null): string {
    return (id !== null && this.people.get(id)?.username) || "?";
  }

  names(ids: number[]): string {
    return ids.map((id) => this.name(id)).join(", ");
  }

  stageLabel(stage: ModElectionStage): string {
    switch (stage.action) {
      case "surplus":
        return i18n("mod_elections.results.stage_surplus", {
          username: this.name(stage.candidate),
        });
      case "exclusion":
        return i18n("mod_elections.results.stage_exclusion", {
          count: stage.excluded.length,
          names: this.names(stage.excluded),
        });
      case "unopposed":
        return i18n("mod_elections.results.stage_unopposed");
      default:
        return i18n("mod_elections.results.stage_first");
    }
  }

  <template>
    <section class="mod-elections-panel mod-elections-results">
      <h2>{{i18n "mod_elections.results.title"}}</h2>

      {{#if this.winners.length}}
        <ol class="mod-elections-results__winners">
          {{#each this.winners as |winner|}}
            <li class="mod-elections-results__winner">
              <a
                data-user-card={{winner.username}}
                href={{profileUrl winner.username}}
              >{{avatar winner imageSize="large"}}</a>
              <div>
                <a
                  class="mod-elections-results__winner-name"
                  data-user-card={{winner.username}}
                  href={{profileUrl winner.username}}
                >{{winner.username}}</a>
                {{#if winner.note}}
                  <span class="mod-elections-muted">{{winner.note}}</span>
                {{else}}
                  <span class="mod-elections-chip mod-elections-chip--strong">
                    {{icon "trophy"}}
                    {{i18n "mod_elections.candidates.elected"}}
                  </span>
                {{/if}}
              </div>
            </li>
          {{/each}}
        </ol>
      {{else}}
        <p class="mod-elections-muted">{{i18n "mod_elections.results.none"}}</p>
      {{/if}}

      {{#each this.countbacks as |line|}}
        <p class="mod-elections-muted">{{line}}</p>
      {{/each}}

      <p class="mod-elections-results__stats">
        <span>{{this.ballotsLine}}</span>
        <span>{{this.quotaLine}}</span>
      </p>

      <h3>{{i18n "mod_elections.results.count_title"}}</h3>
      <div class="mod-elections-results__scroll">
        <table class="mod-elections-results__table">
          <thead>
            <tr>
              <th scope="col">{{i18n "mod_elections.results.candidate"}}</th>
              {{#each this.columns as |column|}}
                <th scope="col">
                  <span
                    class="mod-elections-results__stage-number"
                  >{{column.number}}</span>
                  <span
                    class="mod-elections-results__stage-label"
                  >{{column.label}}</span>
                </th>
              {{/each}}
            </tr>
          </thead>
          <tbody>
            {{#each this.rows as |row|}}
              <tr
                class={{if row.elected "mod-elections-results__row--elected"}}
              >
                <th scope="row">
                  {{avatar row.candidate imageSize="tiny"}}
                  {{row.candidate.username}}
                </th>
                {{#each row.cells as |cell|}}
                  <td
                    class="{{if cell.elected 'is-elected'}}
                      {{if cell.out 'is-out'}}"
                  >
                    {{cell.value}}
                    {{#if cell.elected}}{{icon "check"}}{{/if}}
                    {{#if cell.bar}}
                      <span
                        aria-hidden="true"
                        class="mod-elections-results__bar"
                      >
                        <span style={{cell.bar}}></span>
                      </span>
                    {{/if}}
                  </td>
                {{/each}}
              </tr>
            {{/each}}
            <tr class="mod-elections-results__exhausted">
              <th scope="row">{{i18n "mod_elections.results.exhausted"}}</th>
              {{#each this.exhaustedCells as |value|}}
                <td>{{value}}</td>
              {{/each}}
            </tr>
          </tbody>
        </table>
      </div>

      {{#if this.ties.length}}
        <ul class="mod-elections-results__ties">
          {{#each this.ties as |line|}}
            <li>{{line}}</li>
          {{/each}}
        </ul>
      {{/if}}

      <details class="mod-elections-results__how">
        <summary>{{i18n "mod_elections.results.how"}}</summary>
        <p>{{i18n "mod_elections.results.how_body"}}</p>
        <p>{{i18n "mod_elections.results.how_ties"}}</p>
      </details>
    </section>
  </template>
}
