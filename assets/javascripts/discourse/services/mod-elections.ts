import Service from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import type User from "discourse/models/user";
import type SiteSettingsService from "discourse/services/site-settings";

const BASE = "/jtech-elections";

// ── Payloads (lib/discourse_mod_elections/presenter.rb) ─────────────────

export type ModElectionStatus =
  | "scheduled"
  | "nominating"
  | "voting"
  | "closed"
  | "published"
  | "cancelled";

export interface ModElectionUser {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
}

export interface ModElectionCandidate {
  id: number;
  user: ModElectionUser | null;
  statement: string;
  incumbent: boolean;
  status: "running" | "withdrawn" | "disqualified";
  disqualified_reason: string | null;
  elected: boolean;
  seat_left_reason: "stepped_down" | "removed" | null;
}

// A tie the count had to break: who went out, whose surplus moved first, or
// who is listed first among people elected on equal votes. decided_at is
// the stage whose votes settled it; null when it was drawn by lot.
export interface ModElectionTie {
  purpose: "exclusion" | "surplus" | "order";
  method: "earlier_stage" | "lot";
  among: number[];
  chosen: number;
  decided_at: number | null;
}

export interface ModElectionStage {
  number: number;
  action: "first" | "unopposed" | "surplus" | "exclusion";
  // Whose surplus moved, for a surplus stage.
  candidate: number | null;
  // Who went out, for an exclusion stage: several at once when none of
  // them had a single vote.
  excluded: number[];
  tallies: Record<string, number>;
  exhausted: number;
  elected: number[];
  ties: ModElectionTie[];
}

export interface ModElectionResultCandidate {
  id: number;
  user_id: number;
  username: string | null;
  name: string | null;
  avatar_template: string | null;
  incumbent: boolean;
}

export interface ModElectionResult {
  seats: number;
  quota: number;
  total: number;
  ballots: number;
  outcome: "counted" | "unopposed" | "no_votes";
  seed: number;
  elected: number[];
  exhausted: number;
  candidates: ModElectionResultCandidate[];
  stages: ModElectionStage[];
  countbacks?: { candidate: number; at: string }[];
}

export interface ModElectionTurnout {
  voters: number;
  ballots: number;
  weight: number;
}

export interface ModElection {
  id: number;
  status: ModElectionStatus;
  seats: number;
  nominations_open_at: string;
  voting_open_at: string;
  voting_close_at: string;
  // No more candidates than seats when nominations closed: they stayed
  // open longer, then there was no Vote Week.
  nominations_extended: boolean;
  vote_skipped: boolean;
  // The step strip's dates, as days on the forum's calendar ("January 8").
  days: { nominations: string; voting: string; results: string };
  topic_url: string | null;
  candidates: ModElectionCandidate[];
  result: ModElectionResult | null;
  turnout: ModElectionTurnout | null;
}

export interface ModElectionBallot {
  ranking: number[];
  updated_at: string;
}

export interface ModElectionMe {
  candidate: {
    id: number;
    status: ModElectionCandidate["status"];
    statement: string;
    incumbent: boolean;
  } | null;
  run_blocked: string | null;
  // Running, and nominations or Vote Week still open.
  statement_editable: boolean;
  weight: number | null;
  vote_blocked: string | null;
  ballot: ModElectionBallot | null;
  // Once voting has closed: whether your ballot was counted, or set aside
  // and why. After publishing it's all that's left linking you to a ballot.
  receipt: { counted: boolean; reason: string | null } | null;
}

export interface ModElectionLimits {
  candidate_min_trust_level: number;
  candidate_min_account_age_days: number;
  candidate_clean_record_days: number;
  voter_min_account_age_days: number;
  statement_max_length: number;
}

export interface ModElectionHistoryRow {
  id: number;
  status: ModElectionStatus;
  // "January 2027", in the calendar's time zone.
  label: string;
}

export interface ModElectionPage {
  election: ModElection | null;
  me: ModElectionMe | null;
  limits: ModElectionLimits;
  history: ModElectionHistoryRow[];
  // When the next election opens, as a day on the forum's calendar.
  next_opening: string | null;
  // The step-change channel's last message when this was built
  message_bus_last_id: number;
}

// current_user.mod_election
export interface ModElectionSummary {
  id: number;
  status: ModElectionStatus;
  ends_at: string | null;
  extended: boolean;
  voter?: boolean;
  voted?: boolean;
}

export type ModElectionsCurrentUser = User & {
  can_view_mod_elections?: boolean;
  id: number;
  username: string;
  mod_election?: ModElectionSummary;
};

export type ModElectionsSiteSettings = SiteSettingsService & {
  jtech_enabled: boolean;
  mod_elections_enabled: boolean;
  mod_elections_statement_max_length: number;
};

// The elections page's calls. Every write answers with the whole page
// again, so the page never has to guess what changed.
export default class ModElectionsService extends Service {
  page(id?: number | string | null): Promise<ModElectionPage> {
    return ajax(`${BASE}/current.json`, { data: id ? { id } : {} });
  }

  run(electionId: number, statement: string): Promise<ModElectionPage> {
    return ajax(`${BASE}/${electionId}/candidacy.json`, {
      type: "POST",
      data: { statement },
    });
  }

  updateStatement(
    electionId: number,
    statement: string
  ): Promise<ModElectionPage> {
    return ajax(`${BASE}/${electionId}/candidacy.json`, {
      type: "PUT",
      data: { statement },
    });
  }

  withdraw(electionId: number): Promise<ModElectionPage> {
    return ajax(`${BASE}/${electionId}/candidacy.json`, { type: "DELETE" });
  }

  vote(electionId: number, ranking: number[]): Promise<ModElectionPage> {
    return ajax(`${BASE}/${electionId}/ballot.json`, {
      type: "PUT",
      data: { ranking },
    });
  }

  clearBallot(electionId: number): Promise<ModElectionPage> {
    return ajax(`${BASE}/${electionId}/ballot.json`, { type: "DELETE" });
  }
}
