// The review queue: flagged and queued posts and new users, with the
// actions the server offers for each, as the full site's /review has them:
// filters, claiming, who flagged and why, notes between reviewers, editing
// a queued post before it's approved, and penalties that go with an action.
//
// The list comes in Discourse's side-loaded shape: a reviewable names its
// actions, scores, notes and claim by id, and they're listed beside it.

import { del, errorMessage, get, post as apiPost, put } from "../api.ts";
import { go } from "../app.ts";
import { settings } from "../config.ts";
import { appPathFor, cookedToText } from "../content/cooked.ts";
import { timeAgo, truncate } from "../format.ts";
import { html, type SafeHtml } from "../html.ts";
import { focusContent } from "../nav.ts";
import { href, type RouteContext } from "../router.ts";
import { refreshUser, user } from "../session.ts";
import {
  allCategories,
  avatar,
  categoryBadge,
  categoryName,
  userPath,
} from "../site.ts";
import { icon } from "../ui/icons.ts";
import {
  actionSheet,
  alertDialog,
  confirmDialog,
  type SheetItem,
  toast,
} from "../ui/layers.ts";
import { decodeEntities } from "../ui/topic-row.ts";
import {
  actionLabel,
  actionsOf,
  claimOf,
  historiesOf,
  historyLine,
  type Lookup,
  lookupOf,
  type Note,
  notesOf,
  type ReviewAction,
  type Reviewable,
  type ReviewJson,
  type Score,
  scoresOf,
} from "../staff-logic.ts";
import { useScreen } from "./common.ts";
import { openComposer } from "./composer.ts";
import {
  askDate,
  askText,
  choose,
  chooseUntil,
  isAdminUser,
  localValue,
} from "./staff-common.ts";

const TYPE_LABELS: Record<string, string> = {
  ReviewableFlaggedPost: "Flagged post",
  ReviewableQueuedPost: "Waiting for approval",
  ReviewableUser: "New user",
  ReviewablePost: "Post to review",
  ReviewableChatMessage: "Chat message",
};

const STATUS_LABELS = ["Pending", "Approved", "Rejected", "Ignored", "Deleted"];

// Core sends ten at a time.
const PER_PAGE = 10;

// The query keys the list takes, as core's /review does.
const FILTERS = [
  "status",
  "type",
  "priority",
  "sort_order",
  "category_id",
  "topic_id",
  "username",
  "flagged_by",
  "reviewed_by",
  "claimed_by",
  "score_type",
  "from_date",
  "to_date",
  "offset",
];

type DsaOptions = NonNullable<
  NonNullable<ReviewJson["extras"]>["dsa_classification"]
>;

function reasonOf(scores: Score[]): string {
  const titles: string[] = [];
  scores.forEach((s) => {
    const t = (s.score_type && s.score_type.title) || s.reason || "";
    if (t && titles.indexOf(t) < 0) titles.push(t);
  });
  return titles.join(", ");
}

function titleOf(r: Reviewable): string {
  return decodeEntities(
    r.topic_fancy_title ||
      r.topic_title ||
      r.fancy_title ||
      (r.payload && r.payload.title) ||
      ""
  ).replace(/<[^>]*>/g, "");
}

function bodyOf(r: Reviewable): string {
  if (r.type === "ReviewableUser") {
    const name = r.username || (r.payload && r.payload.username) || "";
    const email = r.email || (r.payload && r.payload.email) || "";
    return name ? "@" + name + (email ? " " + email : "") : email;
  }
  return (
    r.raw ||
    (r.payload && r.payload.raw) ||
    (r.cooked ? cookedToText(r.cooked) : "")
  );
}

function claiming(): string {
  return (settings.staff && settings.staff.reviewableClaiming) || "disabled";
}

export function reviewRoute(ctx: RouteContext): Promise<void> {
  const s = useScreen();
  s.title("Review", { back: true });
  s.loading();
  const query: Record<string, string> = {};
  FILTERS.forEach((k) => {
    if (ctx.query[k]) query[k] = ctx.query[k];
  });
  const qs = (q: Record<string, string>) => {
    const parts: string[] = [];
    for (const k in q)
      if (q.hasOwnProperty(k) && q[k])
        parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(q[k]));
    return parts.join("&");
  };
  const status = query.status || "pending";
  const reload = () => go(ctx.path + location.search, { replace: true });
  const withFilter = (key: string, value: string) => {
    const next: Record<string, string> = {};
    for (const k in query)
      if (query.hasOwnProperty(k) && k !== "offset") next[k] = query[k];
    if (value) next[key] = value;
    else delete next[key];
    const q = qs(next);
    go("/review" + (q ? "?" + q : ""), { replace: true });
  };

  let scoreTypes: Array<{ id: number | string; name: string }> = [];
  let dsa: DsaOptions | null = null;

  // A day, as YYYY-MM-DD; Clear takes the filter off.
  const pickDay = (title: string, key: string) =>
    choose(
      title,
      [
        { label: "Pick a day…", value: "pick" },
        { label: "Clear", value: "" },
      ].map((c) => ({ label: c.label, value: c.value })),
      (v) => {
        if (!v) withFilter(key, "");
        else
          askDate(
            title,
            (d) => withFilter(key, localValue(d).split(" ")[0]),
            new Date(),
            true
          );
      }
    );

  const filterMenu = () => {
    const items: SheetItem[] = [
      {
        label: "Status",
        hint: status,
        run: () =>
          choose(
            "Status",
            [
              { label: "Pending", value: "pending" },
              { label: "Approved", value: "approved" },
              { label: "Rejected", value: "rejected" },
              { label: "Ignored", value: "ignored" },
              { label: "Deleted", value: "deleted" },
              { label: "All reviewed", value: "reviewed" },
              { label: "Everything", value: "all" },
            ].map((c) => ({
              label: c.label,
              value: c.value,
              active: c.value === status,
            })),
            (v) => withFilter("status", v === "pending" ? "" : v)
          ),
      },
      {
        label: "Type",
        hint: query.type ? TYPE_LABELS[query.type] || query.type : "all",
        run: () =>
          choose(
            "Type",
            [{ label: "All types", value: "" }]
              .concat(
                [
                  "ReviewableFlaggedPost",
                  "ReviewableQueuedPost",
                  "ReviewableUser",
                  "ReviewablePost",
                ].map((t) => ({ label: TYPE_LABELS[t], value: t }))
              )
              .map((c) => ({
                label: c.label,
                value: c.value,
                active: c.value === (query.type || ""),
              })),
            (v) => withFilter("type", v)
          ),
      },
      {
        label: "Priority",
        hint: query.priority || "any",
        run: () =>
          choose(
            "At least this priority",
            [
              { label: "Any", value: "" },
              { label: "Low", value: "low" },
              { label: "Medium", value: "medium" },
              { label: "High", value: "high" },
            ].map((c) => ({
              label: c.label,
              value: c.value,
              active: c.value === (query.priority || ""),
            })),
            (v) => withFilter("priority", v)
          ),
      },
      {
        label: "Category",
        hint: query.category_id ? "chosen" : "all",
        run: () =>
          choose(
            "Category",
            [{ label: "All categories", value: "" }]
              .concat(
                allCategories().map((c) => ({
                  label: categoryName(c),
                  value: String(c.id),
                }))
              )
              .map((c) => ({
                label: c.label,
                value: c.value,
                active: c.value === (query.category_id || ""),
              })),
            (v) => withFilter("category_id", v)
          ),
      },
      {
        label: "Order",
        hint: query.sort_order || "score",
        run: () =>
          choose(
            "Order",
            [
              { label: "Highest score first", value: "score" },
              { label: "Lowest score first", value: "score_asc" },
              { label: "Newest first", value: "created_at" },
              { label: "Oldest first", value: "created_at_asc" },
            ].map((c) => ({
              label: c.label,
              value: c.value,
              active: c.value === (query.sort_order || "score"),
            })),
            (v) => withFilter("sort_order", v === "score" ? "" : v)
          ),
      },
      {
        label: "From a member…",
        hint: query.username ? "@" + query.username : undefined,
        run: () =>
          askText(
            "From a member",
            "Username (empty for everyone)",
            (v) => withFilter("username", v.replace(/^@/, "")),
            { optional: true, value: query.username || "" }
          ),
      },
      {
        label: "Flagged by…",
        hint: query.flagged_by ? "@" + query.flagged_by : undefined,
        run: () =>
          askText(
            "Flagged by",
            "Username (empty for anyone)",
            (v) => withFilter("flagged_by", v.replace(/^@/, "")),
            { optional: true, value: query.flagged_by || "" }
          ),
      },
      {
        label: "Reviewed by…",
        hint: query.reviewed_by ? "@" + query.reviewed_by : undefined,
        run: () =>
          askText(
            "Reviewed by",
            "Username (empty for anyone)",
            (v) => withFilter("reviewed_by", v.replace(/^@/, "")),
            { optional: true, value: query.reviewed_by || "" }
          ),
      },
      {
        label: "Claimed by…",
        hint: query.claimed_by ? "@" + query.claimed_by : undefined,
        run: () =>
          askText(
            "Claimed by",
            "Username (empty for anyone)",
            (v) => withFilter("claimed_by", v.replace(/^@/, "")),
            { optional: true, value: query.claimed_by || "" }
          ),
      },
      {
        label: "Reason",
        hint: query.score_type
          ? (
              scoreTypes.filter(
                (t) => String(t.id) === query.score_type
              )[0] || {
                name: query.score_type,
              }
            ).name
          : "any",
        run: () =>
          choose(
            "Reason",
            [{ label: "Any reason", value: "" }]
              .concat(
                scoreTypes.map((t) => ({ label: t.name, value: String(t.id) }))
              )
              .map((c) => ({
                label: c.label,
                value: c.value,
                active: c.value === (query.score_type || ""),
              })),
            (v) => withFilter("score_type", v)
          ),
      },
      {
        label: "From a date…",
        hint: query.from_date || undefined,
        run: () => pickDay("From", "from_date"),
      },
      {
        label: "To a date…",
        hint: query.to_date || undefined,
        run: () => pickDay("To", "to_date"),
      },
    ];
    if (isAdminUser())
      items.push({
        label: "Priorities of flag reasons…",
        icon: "gear",
        run: priorities,
      });
    if (qs(query))
      items.push({
        label: "Clear filters",
        icon: "x",
        run: () => go("/review", { replace: true }),
      });
    actionSheet("Filter", items);
  };
  s.softkeys({ right: { label: "Filter", run: filterMenu } });

  return get<ReviewJson>(
    "/review.json?" + qs(Object.keys(query).length ? query : { status })
  ).then(
    (d) => {
      if (!s.alive()) return;
      const items = d.reviewables || [];
      const l = lookupOf(d);
      scoreTypes = (d.meta && d.meta.score_types) || [];
      dsa = (d.extras && d.extras.dsa_classification) || null;
      const filtered = !!qs(query);
      const filterRow = html`<div class="review-filter" data-row>
        <button type="button" class="btn small" data-act="review-filter">
          ${icon("list")}Filter${filtered ? " (on)" : ""}
        </button>
      </div>`;
      s.act("review-filter", filterMenu);
      if (!items.length) {
        s.render(
          html`${filterRow}
            <p class="state state-empty">
              ${icon("check")}${filtered
                ? "Nothing matches."
                : "Nothing to review."}
            </p>`
        );
        if (!ctx.restore) focusContent(".btn");
        return;
      }
      const rows: SafeHtml[] = items.map((r) => {
        const author =
          l.users[String(r.target_created_by_id || r.created_by_id || 0)];
        const title = titleOf(r);
        const body = bodyOf(r);
        const reason = reasonOf(scoresOf(r, l));
        const claim = claimOf(r, l);
        return html`<li>
          <button
            type="button"
            class="row review"
            data-act="review"
            data-id="${r.id}"
            data-key="rv${r.id}"
          >
            ${author ? avatar(author.avatar_template, 28) : icon("review")}
            <div class="row-main">
              <div class="row-title">
                ${TYPE_LABELS[r.type] ||
                r.type.replace(/^Reviewable/, "")}${reason
                  ? html` · <span class="danger-text">${reason}</span>`
                  : ""}
              </div>
              ${title
                ? html`<div class="row-meta">
                    ${categoryBadge(r.category_id)}<span>${title}</span>
                  </div>`
                : ""}
              ${body
                ? html`<div class="row-excerpt">${truncate(body, 160)}</div>`
                : ""}
              <div class="row-meta">
                ${author
                  ? html`<span>@${author.username}</span>`
                  : ""}<span>${timeAgo(r.created_at)}</span>${r.status
                  ? html`<span>${STATUS_LABELS[r.status] || ""}</span>`
                  : ""}${claim
                  ? html`<span>${icon("lock")}@${claim.username}</span>`
                  : ""}
              </div>
            </div>
          </button>
        </li>`;
      });
      const offset = parseInt(query.offset || "0", 10) || 0;
      const total = (d.meta && d.meta.total_rows_reviewables) || items.length;
      const pager: SafeHtml[] = [];
      if (offset > 0)
        pager.push(
          html`<button
            type="button"
            class="btn small"
            data-act="review-page"
            data-offset="${Math.max(0, offset - PER_PAGE)}"
          >
            ${icon("arrowUp")}Newer page
          </button>`
        );
      if (d.meta && d.meta.load_more_reviewables)
        pager.push(
          html`<button
            type="button"
            class="btn small"
            data-act="review-page"
            data-offset="${offset + PER_PAGE}"
          >
            ${icon("arrowDown")}Next page
          </button>`
        );
      s.render(
        html`${filterRow}
          <p class="hint review-count">
            ${total} ${total === 1 ? "item" : "items"}
          </p>
          <ul class="rows">
            ${rows}
          </ul>
          ${pager.length
            ? html`<div class="review-pager" data-row>${pager}</div>`
            : ""}`
      );
      s.act("review-page", (el) =>
        withFilterOffset(el.getAttribute("data-offset") || "0")
      );
      const withFilterOffset = (o: string) => {
        const next: Record<string, string> = {};
        for (const k in query) if (query.hasOwnProperty(k)) next[k] = query[k];
        if (o && o !== "0") next.offset = o;
        else delete next.offset;
        const q = qs(next);
        go("/review" + (q ? "?" + q : ""), { replace: true });
      };

      s.act("review", (el) => {
        const r = items.filter(
          (x) => String(x.id) === el.getAttribute("data-id")
        )[0];
        if (r) reviewMenu(r, l, reload, dsa);
      });
      if (!ctx.restore) focusContent(".row");
    },
    (e: unknown) =>
      s.error(errorMessage(e), () => go(ctx.path, { replace: true }))
  );
}

function reviewMenu(
  r: Reviewable,
  l: Lookup,
  reload: () => void,
  dsa: DsaOptions | null
): void {
  const items: SheetItem[] = [];
  const scores = scoresOf(r, l);
  const notes = notesOf(r, l);
  const claim = claimOf(r, l);
  const author =
    l.users[String(r.target_created_by_id || r.created_by_id || 0)];
  const claimMode = claiming();
  const mine = !!claim && !!user && claim.id === user.id;
  const pending = r.status === 0;
  // Required claiming: no actions until it's yours.
  const blocked = pending && claimMode === "required" && !mine;
  const otherClaim = !!claim && !mine;

  if (pending && !otherClaim && !blocked)
    actionsOf(r, l).forEach((a) =>
      items.push({
        label: actionLabel(a),
        hint: a.description ? truncate(a.description, 40) : undefined,
        danger: /danger|delete|reject|suspend|silence/i.test(
          (a.button_class || "") + " " + (a.server_action || a.id)
        ),
        run: () => perform(r, a, reload),
      })
    );

  if (pending && r.topic_id && claimMode !== "disabled") {
    if (mine)
      items.push({
        label: "Unclaim",
        icon: "unlock",
        run: () =>
          del(`/reviewable_claimed_topics/${r.topic_id}.json`).then(() => {
            toast("Unclaimed.", "success");
            reload();
          }, failed),
      });
    else if (!claim)
      items.push({
        label: "Claim",
        icon: "lock",
        hint: claimMode === "required" ? "Needed before acting" : undefined,
        run: () =>
          apiPost("/reviewable_claimed_topics.json", {
            reviewable_claimed_topic: { topic_id: r.topic_id },
          }).then(() => {
            toast("Claimed.", "success");
            reload();
          }, failed),
      });
  }
  if (otherClaim)
    items.push({
      label: "Claimed by @" + (claim as { username: string }).username,
      icon: "lock",
      disabled: true,
    });

  items.push({ label: "Details", heading: true });
  const body = bodyOf(r);
  if (body)
    items.push({
      label: "Read it",
      icon: "eye",
      run: () =>
        void alertDialog(
          (titleOf(r) ? titleOf(r) + "\n\n" : "") + body,
          TYPE_LABELS[r.type] || "Review"
        ),
    });
  if (scores.length)
    items.push({
      label: plural(scores.length, "flag"),
      icon: "flag",
      hint: reasonOf(scores),
      run: () =>
        actionSheet(
          "Why it's here",
          scores.map((sc) => {
            const by = sc.user_id ? l.users[String(sc.user_id)] : null;
            const what = (sc.score_type && sc.score_type.title) || "Flag";
            return {
              label: (by ? "@" + by.username + ": " : "") + what,
              hint: sc.created_at ? timeAgo(sc.created_at) : undefined,
              run: sc.reason
                ? () => void alertDialog(sc.reason as string, what)
                : undefined,
            };
          })
        ),
    });
  items.push({
    label: notes.length ? plural(notes.length, "note") : "Add a note…",
    icon: "draft",
    run: () =>
      notes.length ? notesMenu(r, notes, reload) : addNote(r, reload),
  });
  if (pending && r.can_edit && r.type === "ReviewableQueuedPost")
    items.push({
      label: "Edit before approving…",
      icon: "edit",
      run: () => editQueued(r, reload),
    });
  const history = historiesOf(r, l);
  if (history.length)
    items.push({
      label: "History",
      icon: "clock",
      hint: plural(history.length, "entry").replace("entrys", "entries"),
      run: () =>
        actionSheet(
          "History",
          history.map((h) => {
            const by = h.created_by_id
              ? l.users[String(h.created_by_id)]
              : null;
            return {
              label: historyLine(h) + (by ? " by @" + by.username : ""),
              hint: timeAgo(h.created_at),
            };
          })
        ),
    });
  const statements =
    (r.dsa_classification && r.dsa_classification.statement_ids) || [];
  if (
    statements.length &&
    dsa &&
    dsa.community_rules &&
    dsa.community_rules.length &&
    dsa.categories
  ) {
    const rules = dsa.community_rules;
    const categories = dsa.categories;
    items.push({
      label: "Classify for the DSA…",
      icon: "flag",
      run: () =>
        choose(
          "Which rule",
          rules.map((x) => ({ label: x.ground, value: x.id })),
          (rule) =>
            choose(
              "Which category",
              categories.map((x) => ({ label: x.name, value: x.id })),
              (category) =>
                put(`/review/${r.id}/dsa-classification.json`, {
                  community_rule: rule,
                  category,
                  statement_ids: statements,
                }).then(() => {
                  toast("Classified.", "success");
                  reload();
                }, failed)
            )
        ),
    });
  }
  if (author)
    items.push({
      label: "@" + author.username + "'s profile",
      icon: "user",
      href: href(userPath(author.username)),
    });
  const where = appPathFor(r.target_url || r.topic_url || "");
  if (where)
    items.push({ label: "Open in topic", icon: "jump", href: href(where) });

  actionSheet(TYPE_LABELS[r.type] || "Review", items, {
    subtitle: reasonOf(scores) || STATUS_LABELS[r.status] || "",
  });
}

function plural(n: number, word: string): string {
  return n + " " + word + (n === 1 ? "" : "s");
}

function failed(e: unknown): void {
  toast(errorMessage(e), "error");
}

function perform(r: Reviewable, a: ReviewAction, reload: () => void): void {
  const name = a.server_action || a.id;
  const send = (extra: Record<string, unknown> = {}) =>
    put<{ reviewable_perform_result?: { success?: boolean } }>(
      `/review/${r.id}/perform/${encodeURIComponent(name)}.json?version=${r.version}`,
      extra
    ).then(() => {
      toast("Done.", "success");
      void refreshUser();
      reload();
    }, failed);

  // Penalties that go with the action: ask for them as the admin page does.
  if (a.client_action === "suspend" || a.client_action === "silence") {
    const suspend = a.client_action === "suspend";
    const post = r.target_type === "Post" && r.target_id ? r.target_id : 0;
    // What happens to the post as well, as the full site's penalty asks.
    const withPost = (penalty: Record<string, unknown>) => {
      if (!post) {
        void send(penalty);
        return;
      }
      const choices = [
        { label: "Leave the post", value: "none" },
        { label: "Delete the post", value: "delete" },
        { label: "Delete the post and its replies", value: "delete_replies" },
      ];
      if (suspend)
        choices.push({ label: "Delete all their posts", value: "delete_all" });
      choices.push({ label: "Edit the post", value: "edit" });
      choose("And the post", choices, (action) => {
        const extra: Record<string, unknown> = {
          post_id: post,
          post_action: action,
        };
        for (const k in penalty)
          if (penalty.hasOwnProperty(k)) extra[k] = penalty[k];
        if (action !== "edit") {
          void send(extra);
          return;
        }
        askText(
          "Edit the post",
          "Post",
          (text) => {
            extra.post_edit = text;
            void send(extra);
          },
          { value: r.raw || "", ok: a.label }
        );
      });
    };
    chooseUntil(suspend ? "Suspend until" : "Silence until", (until) =>
      askText(a.label, "Why (the member sees this)", (reason) =>
        askText(
          a.label,
          "A message to email them (optional)",
          (message) =>
            withPost(
              suspend
                ? { suspend_until: until.toISOString(), reason, message }
                : { silenced_till: until.toISOString(), reason, message }
            ),
          { optional: true, ok: a.label }
        )
      )
    );
    return;
  }
  if (a.client_action === "edit") {
    editFlagged(r, () => void send());
    return;
  }
  if (a.client_action === "scrub") {
    askText(a.label, "Why the data is being removed", (reason) =>
      put(`/review/${r.id}/scrub.json`, { reason }).then(() => {
        toast("Done.", "success");
        reload();
      }, failed)
    );
    return;
  }
  if (name === "revise_and_reject_post") {
    askText(a.label, "What needs changing", (reason) =>
      askText(
        a.label,
        "More for them (optional)",
        (feedback) =>
          void send({
            revise_reason: "other_reason",
            revise_custom_reason: reason,
            revise_feedback: feedback,
          }),
        { optional: true, ok: a.label }
      )
    );
    return;
  }
  if (a.require_reject_reason) {
    askText(
      a.label,
      "Why (sent to them)",
      (reason) => void send({ reject_reason: reason, send_email: true }),
      { optional: true, ok: a.label }
    );
    return;
  }
  if (a.confirm_message) {
    confirmDialog(a.confirm_message, { ok: actionLabel(a), danger: true }).then(
      (ok) => ok && void send()
    );
    return;
  }
  void send();
}

// A flagged post edited in place, then the action ("edit post") recorded.
function editFlagged(r: Reviewable, after: () => void): void {
  if (r.target_type !== "Post" || !r.target_id || !r.topic_id) {
    toast("Edit it from the topic.", "error");
    return;
  }
  const postId = r.target_id;
  const topicId = r.topic_id;
  get<{ raw?: string; post_number?: number }>(`/posts/${postId}.json`).then(
    (p) =>
      openComposer({
        kind: "edit",
        topicId,
        topicTitle: titleOf(r),
        postId,
        postNumber: p.post_number || 0,
        raw: p.raw || "",
        categoryId: r.category_id || null,
        editTitle: null,
        onSaved: after,
      }),
    failed
  );
}

function editQueued(r: Reviewable, reload: () => void): void {
  const fields = (r.editable_fields || []).map((f) => f.id);
  const save = (change: Record<string, unknown>) =>
    put(`/review/${r.id}.json?version=${r.version}`, {
      reviewable: change,
    }).then(() => {
      toast("Saved.", "success");
      reload();
    }, failed);
  const items: SheetItem[] = [];
  if (fields.indexOf("payload.raw") >= 0)
    items.push({
      label: "The post",
      icon: "edit",
      run: () =>
        askText("Edit the post", "Post", (raw) => save({ payload: { raw } }), {
          value: (r.payload && r.payload.raw) || "",
          ok: "Save",
        }),
    });
  if (fields.indexOf("payload.title") >= 0 && r.payload && r.payload.title)
    items.push({
      label: "The title",
      icon: "edit",
      run: () =>
        askText(
          "Edit the title",
          "Title",
          (title) => save({ payload: { title } }),
          { value: r.payload ? r.payload.title || "" : "", ok: "Save" }
        ),
    });
  if (fields.indexOf("category_id") >= 0)
    items.push({
      label: "The category",
      icon: "grid",
      run: () =>
        choose(
          "Category",
          allCategories().map((c) => ({
            label: categoryName(c),
            value: String(c.id),
            active: c.id === r.category_id,
          })),
          (v) => save({ category_id: parseInt(v, 10) })
        ),
    });
  if (!items.length) {
    toast("Nothing here can be edited.", "error");
    return;
  }
  actionSheet("Edit before approving", items);
}

function addNote(r: Reviewable, reload: () => void): void {
  askText("Note for reviewers", "Only reviewers see it", (content) =>
    apiPost(`/review/${r.id}/notes.json`, {
      reviewable_note: { content },
    }).then(() => {
      toast("Note added.", "success");
      reload();
    }, failed)
  );
}

function notesMenu(r: Reviewable, notes: Note[], reload: () => void): void {
  const items: SheetItem[] = [
    { label: "Add a note…", icon: "plus", run: () => addNote(r, reload) },
  ];
  notes.forEach((n) =>
    items.push({
      label: truncate(n.content, 60),
      hint:
        (n.user ? "@" + n.user.username + ", " : "") + timeAgo(n.created_at),
      run: () => {
        const list: SheetItem[] = [
          {
            label: "Read it",
            icon: "eye",
            run: () => void alertDialog(n.content, "Note"),
          },
        ];
        if (n.user && user && (n.user.id === user.id || user.admin))
          list.push({
            label: "Delete it",
            icon: "trash",
            danger: true,
            run: () =>
              del(`/review/${r.id}/notes/${n.id}.json`).then(() => {
                toast("Note deleted.", "success");
                reload();
              }, failed),
          });
        actionSheet("Note", list, { subtitle: truncate(n.content, 80) });
      },
    })
  );
  actionSheet("Notes", items);
}

interface ScoreTypeSetting {
  id: number;
  title: string;
  reviewable_priority: number;
}

// How much each flag reason weighs in the queue (admins), as on the full
// site's review settings.
function priorities(): void {
  get<{
    reviewable_score_types?: ScoreTypeSetting[];
    reviewable_settings?: {
      reviewable_priorities?: Array<{ id: number; name: string }>;
    };
  }>("/review/settings.json").then((d) => {
    const types = d.reviewable_score_types || [];
    const levels =
      (d.reviewable_settings && d.reviewable_settings.reviewable_priorities) ||
      [];
    const nameOf = (n: number) =>
      (levels.filter((x) => x.id === n)[0] || { name: String(n) }).name;
    actionSheet(
      "Priorities",
      types.map((t) => ({
        label: t.title,
        hint: nameOf(t.reviewable_priority),
        run: () =>
          choose(
            t.title,
            levels.map((x) => ({
              label: x.name,
              value: String(x.id),
              active: x.id === t.reviewable_priority,
            })),
            (v) => {
              const body: Record<string, number> = {};
              body[String(t.id)] = parseInt(v, 10);
              put("/review/settings.json", {
                reviewable_priorities: body,
              }).then(() => toast("Priority saved.", "success"), failed);
            }
          ),
      }))
    );
  }, failed);
}
