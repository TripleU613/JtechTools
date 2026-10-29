import assert from "node:assert/strict";
import { test } from "node:test";
import {
  actionLabel,
  actionsOf,
  claimOf,
  historiesOf,
  historyLine,
  lookupOf,
  notesOf,
  parseLocalDateTime,
  type ReviewJson,
  scoresOf,
  topicIdFrom,
} from "../src/staff-logic.ts";

test("a typed date and time is read as local time", () => {
  const d = parseLocalDateTime("2026-11-05 14:30") as Date;
  assert.equal(d.getFullYear(), 2026);
  assert.equal(d.getMonth(), 10);
  assert.equal(d.getDate(), 5);
  assert.equal(d.getHours(), 14);
  assert.equal(d.getMinutes(), 30);
  // A date alone means 8 in the morning.
  assert.equal((parseLocalDateTime(" 2026-1-2 ") as Date).getHours(), 8);
  assert.equal(parseLocalDateTime("next tuesday"), null);
  assert.equal(parseLocalDateTime(""), null);
});

test("a topic is found by its number or any link to it", () => {
  assert.equal(topicIdFrom("123"), 123);
  assert.equal(topicIdFrom(" 123 "), 123);
  assert.equal(topicIdFrom("/t/flip-phones/123"), 123);
  assert.equal(topicIdFrom("/t/flip-phones/123/4"), 123);
  assert.equal(topicIdFrom("/t/123/4"), 123);
  assert.equal(topicIdFrom("/t/123"), 123);
  assert.equal(
    topicIdFrom("https://forum.example.com/t/kyocera-dura-xv/456?u=bob"),
    456
  );
  assert.equal(topicIdFrom("https://forum.example.com/dumb/t/x/789#p2"), 789);
  assert.equal(topicIdFrom("kyocera"), 0);
  assert.equal(topicIdFrom("/u/bob"), 0);
});

// The shape /review.json sends (as core's own test fixture has it).
const REVIEW: ReviewJson = {
  reviewables: [
    {
      id: 4321,
      type: "ReviewableQueuedPost",
      status: 0,
      version: 1,
      created_at: "2026-10-01T10:00:00Z",
      topic_id: 77,
      bundled_action_ids: ["4321-approve", "4321-reject"],
      reviewable_score_ids: [1, 2],
      reviewable_note_ids: [9],
      claimed_by_id: 5,
      reviewable_history_ids: [20, 21],
    },
  ],
  bundled_actions: [
    { id: "4321-approve", action_ids: ["4321-approve_post"] },
    {
      id: "4321-reject",
      action_ids: ["4321-reject_post", "4321-revise_and_reject_post"],
    },
  ],
  actions: [
    {
      id: "4321-approve_post",
      label: "Approve",
      server_action: "approve_post",
    },
    { id: "4321-reject_post", label: "Reject", server_action: "reject_post" },
    {
      id: "4321-revise_and_reject_post",
      label: "Revise…",
      server_action: "revise_and_reject_post",
    },
  ],
  reviewable_scores: [
    { id: 1, user_id: 3, score_type: { title: "Spam" } },
    { id: 2, user_id: 4, score_type: { title: "Off-topic" } },
  ],
  reviewable_notes: [
    {
      id: 9,
      content: "Looks like a repost",
      created_at: "2026-10-01T11:00:00Z",
    },
  ],
  claimed_bies: [{ id: 5, automatic: false, user_id: 3 }],
  reviewable_histories: [
    {
      id: 20,
      created_at: "2026-10-01T10:00:00Z",
      reviewable_history_type: 0,
      status: 0,
    },
    {
      id: 21,
      created_at: "2026-10-01T12:00:00Z",
      reviewable_history_type: 1,
      status: 1,
    },
  ],
  users: [
    { id: 3, username: "mod_m", avatar_template: "" },
    { id: 4, username: "bob", avatar_template: "" },
  ],
};

test("a reviewable's side-loaded actions, flags, notes and claim come back together", () => {
  const l = lookupOf(REVIEW);
  const r = (REVIEW.reviewables || [])[0];
  assert.deepEqual(
    actionsOf(r, l).map((a) => a.server_action),
    ["approve_post", "reject_post", "revise_and_reject_post"]
  );
  assert.deepEqual(
    scoresOf(r, l).map((s) => s.score_type && s.score_type.title),
    ["Spam", "Off-topic"]
  );
  assert.deepEqual(
    notesOf(r, l).map((n) => n.content),
    ["Looks like a repost"]
  );
  assert.deepEqual(claimOf(r, l), { username: "mod_m", id: 3 });
  assert.deepEqual(historiesOf(r, l).map(historyLine), [
    "Created",
    "Status changed to approved",
  ]);
});

test("inline objects are taken as they are, and missing ones are skipped", () => {
  const l = lookupOf({});
  const r = {
    id: 1,
    type: "ReviewableUser",
    status: 0,
    version: 0,
    created_at: "2026-10-01T10:00:00Z",
    bundled_actions: [
      { id: "1-approve", actions: [{ id: "approve_user", label: "Approve" }] },
    ],
    bundled_action_ids: ["gone"],
    reviewable_score_ids: [404],
  };
  assert.deepEqual(
    actionsOf(r, l).map((a) => a.id),
    ["approve_user"]
  );
  assert.deepEqual(scoresOf(r, l), []);
  assert.equal(claimOf(r, l), null);
});

test("a bare Yes or No says what it does", () => {
  assert.equal(actionLabel({ id: "approve_post", label: "Yes" }), "Approve");
  assert.equal(actionLabel({ id: "reject", label: "No" }), "Reject");
  assert.equal(
    actionLabel({ id: "disagree", label: "Keep post" }),
    "Keep post"
  );
});
