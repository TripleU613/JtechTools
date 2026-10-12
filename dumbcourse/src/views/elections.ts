// Mod elections on a flip phone: who's running, running yourself, and a
// ballot ranked with the keypad (1–9 puts the candidate in that place, 0
// takes them off). Same JSON API as the full site (/jtech-elections/*); the
// server does every check.

import { del, errorMessage, get, post, put } from "../api.ts";
import { dateTime, longDate, plural, timeAgo, truncate } from "../format.ts";
import { html, type SafeHtml } from "../html.ts";
import { focusContent } from "../nav.ts";
import { href, type RouteContext } from "../router.ts";
import { avatar } from "../site.ts";
import { icon } from "../ui/icons.ts";
import {
  actionSheet,
  alertDialog,
  confirmDialog,
  promptDialog,
  toast,
  type SheetItem,
} from "../ui/layers.ts";
import { moveBy, placeAt, removeFrom, sameRanking } from "../ballot.ts";
import { useScreen } from "./common.ts";
import type { Screen } from "../screen.ts";

interface Person {
  id: number;
  username: string;
  name?: string | null;
  avatar_template: string;
}

interface Candidate {
  id: number;
  user: Person | null;
  statement: string;
  incumbent: boolean;
  status: string;
  disqualified_reason: string | null;
  elected: boolean;
}

interface Tie {
  purpose: string;
  method: string;
  among: number[];
  chosen: number;
  decided_at: number | null;
}

interface Stage {
  number: number;
  action: string;
  candidate: number | null;
  excluded: number[];
  tallies: Record<string, number>;
  elected: number[];
  ties: Tie[];
}

interface Result {
  quota: number;
  ballots: number;
  seed: number;
  elected: number[];
  candidates: Array<{ id: number; username: string | null }>;
  stages: Stage[];
}

interface Election {
  id: number;
  status: string;
  seats: number;
  voting_open_at: string;
  voting_close_at: string;
  candidates: Candidate[];
  result: Result | null;
}

interface Me {
  candidate: { id: number; status: string; statement: string } | null;
  run_blocked: string | null;
  weight: number | null;
  vote_blocked: string | null;
  ballot: {
    ranking: number[];
    voided: boolean;
    void_reason: string | null;
    updated_at: string;
  } | null;
}

interface Page {
  election: Election | null;
  me: Me | null;
  limits: {
    candidate_min_trust_level: number;
    candidate_min_account_age_days: number;
    candidate_clean_record_days: number;
    voter_min_account_age_days: number;
    statement_max_length: number;
  };
  history: Array<{ id: number; status: string; label: string }>;
  next_opening: string | null;
}

const API = "/jtech-elections";

const STATUS: Record<string, string> = {
  nominating: "Nominations open",
  voting: "Vote Week",
  closed: "Counting",
  published: "Results",
  cancelled: "Cancelled",
};

// ── Words ───────────────────────────────────────────────────────────────

function blockedText(reason: string, page: Page): string {
  const l = page.limits;
  switch (reason) {
    case "trust_level":
      return "Candidates need trust level " + l.candidate_min_trust_level + ".";
    case "account_age":
      return (
        "Candidates need an account at least " +
        l.candidate_min_account_age_days +
        " days old."
      );
    case "record":
      return (
        "Accounts suspended or silenced in the last " +
        l.candidate_clean_record_days +
        " days can't run."
      );
    case "admin":
      return "Admins don't run or vote.";
    case "disqualified":
      return "You were taken off the ballot for this election.";
    case "not_on_roll":
      return (
        "You weren't on the voter list when nominations opened. Voters need trust level 1 and an account at least " +
        l.voter_min_account_age_days +
        " days old by then."
      );
    default:
      return "Your account can't take part right now.";
  }
}

function nameOf(c: Candidate): string {
  return c.user ? c.user.username : "?";
}

function candidateRow(c: Candidate, side: SafeHtml | string = ""): SafeHtml {
  const u = c.user;
  return html`<li>
    <a
      class="row"
      href="${u ? href("/u/" + encodeURIComponent(u.username)) : "#"}"
      data-key="cand${c.id}"
    >
      ${u ? avatar(u.avatar_template, 28) : ""}
      <div class="row-main">
        <div class="row-title">
          ${nameOf(c)}
          ${c.incumbent
            ? html` <span class="pill waiting">Moderator</span>`
            : ""}
          ${c.elected ? html` <span class="pill">Elected</span>` : ""}
        </div>
        ${c.status === "disqualified"
          ? html`<div class="row-meta">
              Taken off the ballot: ${c.disqualified_reason || ""}
            </div>`
          : c.statement
            ? html`<div class="row-meta">${truncate(c.statement, 160)}</div>`
            : ""}
      </div>
      ${side}
    </a>
  </li>`;
}

function candidateList(e: Election): SafeHtml {
  const running = e.candidates.filter((c) => c.status === "running").length;
  return html`<h2 class="section-title">Running (${running})</h2>
    ${e.candidates.length
      ? html`<ul class="rows">
          ${e.candidates.map((c) => candidateRow(c))}
        </ul>`
      : html`<p class="hint pad">Nobody is running yet.</p>`}`;
}

// ── The screen ──────────────────────────────────────────────────────────

export function electionsRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  s.title("Mod elections", { back: true });
  s.loading();
  const id = ctx.query.id;
  const path =
    API + "/current.json" + (id ? "?id=" + encodeURIComponent(id) : "");
  return get<Page>(path).then(
    (page) => {
      if (s.alive()) show(s, page);
    },
    (e: unknown) => s.error(errorMessage(e), () => void electionsRoute(ctx))
  );
}

function show(s: Screen, page: Page): void {
  const e = page.election;
  if (!e) {
    s.empty(
      "There hasn't been an election yet." +
        (page.next_opening
          ? " Nominations open " + longDate(page.next_opening) + "."
          : ""),
      "info"
    );
    return;
  }
  const ends =
    e.status === "nominating"
      ? e.voting_open_at
      : e.status === "voting"
        ? e.voting_close_at
        : null;
  s.title("Mod elections", {
    back: true,
    sub: (STATUS[e.status] || "") + (ends ? " · until " + dateTime(ends) : ""),
  });

  if (e.status === "voting" && page.me && !page.me.vote_blocked) {
    ballot(s, page, e, page.me);
    return;
  }

  let body: SafeHtml;
  if (e.status === "nominating") body = nominations(s, page, e);
  else if (e.status === "voting")
    body = html`${page.me && page.me.vote_blocked
      ? html`<p class="hint pad">${blockedText(page.me.vote_blocked, page)}</p>`
      : ""}${candidateList(e)}`;
  else if (e.status === "closed")
    body = html`<p class="hint pad">
        Voting has closed. The results come out when an admin publishes the
        count.
      </p>
      ${candidateList(e)}`;
  else if (e.status === "published" && e.result)
    body = results(e, e.result, page.me);
  else
    body = html`<p class="hint pad">
      This election was cancelled. The moderators stayed as they were.
    </p>`;

  s.render(html`${body}${history(page)}`);
  focusContent();
}

function history(page: Page): SafeHtml | string {
  const current = page.election ? page.election.id : 0;
  const past = page.history.filter((h) => h.id !== current);
  if (!past.length) return "";
  return html`<h2 class="section-title">Past elections</h2>
    <ul class="rows">
      ${past.map(
        (h) =>
          html`<li>
            <a
              class="row"
              href="${href("/elections?id=" + h.id)}"
              data-key="past${h.id}"
            >
              <div class="row-main">
                <div class="row-title">${h.label}</div>
                ${h.status === "cancelled"
                  ? html`<div class="row-meta">Cancelled</div>`
                  : ""}
              </div>
            </a>
          </li>`
      )}
    </ul>`;
}

// ── Nominations ─────────────────────────────────────────────────────────

function nominations(s: Screen, page: Page, e: Election): SafeHtml {
  const me = page.me;
  const mine = me && me.candidate && me.candidate.status === "running";
  const max = page.limits.statement_max_length;

  const save = (statement: string, first: boolean) =>
    (first
      ? post<Page>(API + "/" + e.id + "/candidacy.json", { statement })
      : put<Page>(API + "/" + e.id + "/candidacy.json", { statement })
    ).then(
      (next) => {
        toast(first ? "You're running." : "Saved.", "success");
        if (s.alive()) show(s, next);
      },
      (err: unknown) => toast(errorMessage(err), "error")
    );

  const ask = (first: boolean) => {
    if (!max) return void save("", first);
    void promptDialog("About you", {
      title: "Run for mod",
      multiline: true,
      value: (me && me.candidate && me.candidate.statement) || "",
      placeholder: "What would you do as a moderator?",
      hint: "Up to " + max + " characters.",
      ok: first ? "Run" : "Save",
    }).then((text) => {
      if (text !== null) void save(text, first);
    });
  };

  s.act("run", () => ask(true));
  s.act("edit", () => ask(false));
  s.act("withdraw", () => {
    void confirmDialog(
      "Drop out of this election? You can run again until nominations close.",
      { ok: "Drop out", danger: true }
    ).then((yes) => {
      if (!yes) return;
      del<Page>(API + "/" + e.id + "/candidacy.json").then(
        (next) => {
          if (s.alive()) show(s, next);
        },
        (err: unknown) => toast(errorMessage(err), "error")
      );
    });
  });

  let mineBlock: SafeHtml | string = "";
  if (me && mine) {
    mineBlock = html`<p class="hint pad"><b>You're running.</b></p>
      <div class="pad" data-row>
        ${max
          ? html`<button type="button" class="btn" data-act="edit">
              ${icon("edit")} Edit statement
            </button>`
          : ""}
        <button type="button" class="btn danger" data-act="withdraw">
          Drop out
        </button>
      </div>`;
  } else if (me && !me.run_blocked) {
    mineBlock = html`<div class="pad" data-row>
      <button type="button" class="btn primary" data-act="run">
        ${icon("check")} Run for mod
      </button>
    </div>`;
  } else if (me && me.run_blocked && me.run_blocked !== "already_running") {
    mineBlock = html`<p class="hint pad">
      ${blockedText(me.run_blocked, page)}
    </p>`;
  }
  return html`${mineBlock}${candidateList(e)}`;
}

// ── Ballot ──────────────────────────────────────────────────────────────

function ballot(s: Screen, page: Page, e: Election, me: Me): void {
  const running = e.candidates.filter((c) => c.status === "running");
  const byId: Record<string, Candidate> = {};
  running.forEach((c) => (byId[String(c.id)] = c));
  const known = (id: number) => !!byId[String(id)];
  let saved = (me.ballot ? me.ballot.ranking : []).filter(known);
  let ranking = saved.slice();
  // A candidate can't rank themselves; the server says so too, but there's
  // no need to offer it.
  const selfId = me.candidate ? me.candidate.id : 0;

  const focusedId = (): number => {
    const el = document.activeElement;
    const raw = el ? el.getAttribute("data-id") : null;
    return raw ? parseInt(raw, 10) : 0;
  };

  const draw = (focusId?: number) => {
    const dirty = !sameRanking(ranking, saved);
    const ranked = ranking.map((id) => byId[String(id)]);
    const unranked = running.filter((c) => ranking.indexOf(c.id) < 0);
    const row = (c: Candidate, place: number) =>
      html`<li>
        <button
          type="button"
          class="row"
          data-act="${c.id === selfId ? "self" : "cand"}"
          data-id="${String(c.id)}"
          data-key="b${c.id}"
        >
          ${place
            ? html`<span class="pill">${String(place)}</span>&nbsp;`
            : ""}${c.user ? avatar(c.user.avatar_template, 28) : ""}
          <div class="row-main">
            <div class="row-title">
              ${nameOf(c)}
              ${c.incumbent
                ? html` <span class="pill waiting">Moderator</span>`
                : ""}
            </div>
            ${c.statement
              ? html`<div class="row-meta">${truncate(c.statement, 80)}</div>`
              : ""}
          </div>
          ${c.id === selfId ? html`<span class="row-side">You</span>` : ""}
        </button>
      </li>`;

    s.render(
      html`${me.ballot && me.ballot.voided
        ? html`<p class="hint pad">
            An admin set your ballot aside: ${me.ballot.void_reason || ""}
          </p>`
        : html`<p class="hint pad">
              Your vote counts ${String(me.weight || 0)}. On a candidate, press
              1–9 to put them in that place, 0 to take them off.
            </p>
            <h2 class="section-title">Your ranking</h2>
            ${ranked.length
              ? html`<ul class="rows">
                  ${ranked.map((c, i) => row(c, i + 1))}
                </ul>`
              : html`<p class="hint pad">Nobody ranked yet.</p>`}
            <h2 class="section-title">Candidates</h2>
            ${unranked.length
              ? html`<ul class="rows">
                  ${unranked.map((c) => row(c, 0))}
                </ul>`
              : html`<p class="hint pad">Everyone is ranked.</p>`}
            <p class="hint pad">
              ${dirty
                ? "Not saved"
                : me.ballot
                  ? "Saved " + timeAgo(me.ballot.updated_at)
                  : "Not saved yet"}
            </p>
            <div class="pad" data-row>
              <button
                type="button"
                class="btn primary"
                data-act="save"
                ${dirty && ranking.length ? "" : "disabled"}
              >
                ${icon("check")} Save ballot
              </button>
              ${me.ballot
                ? html`<button type="button" class="btn" data-act="clear">
                    Take back
                  </button>`
                : ""}
            </div>`}${history(page)}`
    );
    s.softkeys({
      right: dirty && ranking.length ? { label: "Save", run: save } : null,
    });
    focusContent(focusId ? '[data-key="b' + focusId + '"]' : undefined);
  };

  const change = (next: number[], id: number) => {
    ranking = next;
    draw(id);
  };

  const save = () => {
    if (!ranking.length) return;
    put<Page>(API + "/" + e.id + "/ballot.json", { ranking }).then(
      (next) => {
        toast("Ballot saved.", "success");
        if (!s.alive()) return;
        me = next.me || me;
        saved = (me.ballot ? me.ballot.ranking : []).filter(known);
        ranking = saved.slice();
        draw(focusedId());
      },
      (err: unknown) => toast(errorMessage(err), "error")
    );
  };

  const place = (n: number) => () => {
    const id = focusedId();
    if (!id || id === selfId || !known(id)) return;
    change(n ? placeAt(ranking, id, n) : removeFrom(ranking, id), id);
  };
  s.keys({
    "1": place(1),
    "2": place(2),
    "3": place(3),
    "4": place(4),
    "5": place(5),
    "6": place(6),
    "7": place(7),
    "8": place(8),
    "9": place(9),
    "0": place(0),
  });

  s.act("save", save);
  s.act("self", () => void alertDialog("You can't vote for yourself."));
  s.act("clear", () => {
    void confirmDialog(
      "Take back your ballot? You can vote again until Vote Week ends.",
      { ok: "Take back", danger: true }
    ).then((yes) => {
      if (!yes) return;
      del<Page>(API + "/" + e.id + "/ballot.json").then(
        (next) => {
          if (!s.alive()) return;
          me = next.me || me;
          saved = [];
          ranking = [];
          draw();
        },
        (err: unknown) => toast(errorMessage(err), "error")
      );
    });
  });
  s.act("cand", (el) => {
    const id = parseInt(el.getAttribute("data-id") || "0", 10);
    const c = byId[String(id)];
    if (!c) return;
    const at = ranking.indexOf(id);
    const items: SheetItem[] = [];
    if (at < 0) {
      items.push({
        label:
          "Rank " + (ranking.length + 1) + (ranking.length ? "" : " (first)"),
        icon: "plus",
        run: () => change(placeAt(ranking, id, ranking.length + 1), id),
      });
    } else {
      if (at > 0)
        items.push({
          label: "Move up",
          icon: "jump",
          run: () => change(moveBy(ranking, id, -1), id),
        });
      if (at < ranking.length - 1)
        items.push({
          label: "Move down",
          icon: "jump",
          run: () => change(moveBy(ranking, id, 1), id),
        });
      items.push({
        label: "Take off my ranking",
        icon: "x",
        danger: true,
        run: () => change(removeFrom(ranking, id), id),
      });
    }
    if (c.statement)
      items.push({
        label: "Read statement",
        icon: "info",
        run: () => void alertDialog(c.statement, nameOf(c)),
      });
    if (c.user)
      items.push({
        label: "Profile",
        icon: "user",
        href: href("/u/" + encodeURIComponent(c.user.username)),
      });
    actionSheet(nameOf(c), items, {
      subtitle: at < 0 ? "Not ranked" : "Ranked " + (at + 1),
    });
  });

  draw();
}

// ── Results ─────────────────────────────────────────────────────────────

// Whether the reader's own ballot went into the count, never what was on it.
function receipt(me: Me | null): SafeHtml | string {
  if (!me || !me.ballot) return "";
  return html`<p class="hint pad">
    ${me.ballot.voided
      ? "An admin set your ballot aside: " + (me.ballot.void_reason || "")
      : "Your ballot was counted."}
  </p>`;
}

function tieText(
  t: Tie,
  st: Stage,
  n: (id: number | null) => string,
  seed: number
): string {
  const what =
    t.purpose === "exclusion"
      ? "put " + n(t.chosen) + " out"
      : t.purpose === "surplus"
        ? "moved " + n(t.chosen) + "'s extra votes first"
        : "listed " + n(t.chosen) + " ahead";
  const how =
    t.method === "lot"
      ? " were level at every stage. A lot (seed " + seed + ") "
      : " were level. Stage " + t.decided_at + " ";
  return (
    "Stage " + st.number + ": " + t.among.map(n).join(", ") + how + what + "."
  );
}

function results(e: Election, r: Result, me: Me | null): SafeHtml {
  const names: Record<string, string> = {};
  r.candidates.forEach((c) => (names[String(c.id)] = c.username || "?"));
  const n = (id: number | null) =>
    id === null ? "?" : names[String(id)] || "?";
  const stageLabel = (st: Stage) =>
    st.action === "surplus"
      ? n(st.candidate) + "'s extra votes move on"
      : st.action === "exclusion"
        ? st.excluded.map(n).join(", ") +
          (st.excluded.length > 1 ? " are out" : " is out")
        : st.action === "unopposed"
          ? "Unopposed"
          : "First choices";
  const byId: Record<string, Candidate> = {};
  e.candidates.forEach((c) => (byId[String(c.id)] = c));
  // In the order they were elected.
  const winners = r.elected.map((id) => byId[String(id)]).filter((c) => !!c);
  const ties: string[] = [];
  r.stages.forEach((st) =>
    st.ties.forEach((t) => ties.push(tieText(t, st, n, r.seed)))
  );
  // Who is out by each stage, so a stage lists only who's still in it.
  const outBy: Record<string, number> = {};
  r.stages.forEach((st) =>
    st.excluded.forEach((id) => (outBy[String(id)] = st.number))
  );
  const tallies = (st: Stage) =>
    r.candidates
      .filter(
        (c) =>
          st.tallies[String(c.id)] !== undefined &&
          !(outBy[String(c.id)] <= st.number)
      )
      .sort((a, b) => st.tallies[String(b.id)] - st.tallies[String(a.id)])
      .slice(0, 4)
      .map(
        (c) =>
          n(c.id) +
          " " +
          String(Math.round(st.tallies[String(c.id)] * 100) / 100)
      )
      .join(" · ");

  return html`${receipt(me)}
    <h2 class="section-title">Elected</h2>
    ${winners.length
      ? html`<ul class="rows">
          ${winners.map((c) => candidateRow(c))}
        </ul>`
      : html`<p class="hint pad">Nobody was elected.</p>`}
    <p class="hint pad">
      ${plural(r.ballots, "ballot")} counted ·
      ${String(Math.round(r.quota * 100) / 100)} votes to win a seat
    </p>
    <h2 class="section-title">The count</h2>
    <ul class="rows">
      ${r.stages.map(
        (st) =>
          html`<li>
            <div class="row">
              <div class="row-main">
                <div class="row-title">
                  ${String(st.number)}. ${stageLabel(st)}
                </div>
                ${st.elected.length
                  ? html`<div class="row-meta">
                      Elected: ${st.elected.map(n).join(", ")}
                    </div>`
                  : ""}
                <div class="row-meta">${tallies(st)}</div>
              </div>
            </div>
          </li>`
      )}
    </ul>
    ${ties.length
      ? html`<h2 class="section-title">Ties</h2>
          ${ties.map((t) => html`<p class="hint pad">${t}</p>`)}`
      : ""}`;
}
