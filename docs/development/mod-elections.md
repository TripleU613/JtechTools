# Mod elections — how they're built

How the [mod elections](../features/mod-elections.md) module works inside, for people changing it. The namespace is `DiscourseModElections` (not `DiscourseElections`, so it can't collide with the third-party discourse-elections plugin), the switch is `DiscourseModElections.enabled?` (`jtech_enabled` and `mod_elections_enabled`), and the wiring is in [`sub_plugins/mod_elections.rb`](../../sub_plugins/mod_elections.rb).

## Layout

| Path | What's there |
| --- | --- |
| `app/models/discourse_mod_elections/` | `Election`, `Candidate`, `Voter` (the roll), `Ballot` |
| `lib/discourse_mod_elections/stv.rb` | The count: plain Ruby, no database |
| `lib/discourse_mod_elections/tally.rb` | Feeds an election's ballots to `Stv` and turns the result into the stored JSON |
| `lib/discourse_mod_elections/schedule.rb` | The calendar: which months, what time zone, when the next one opens |
| `lib/discourse_mod_elections/lifecycle.rb` | Moves elections along the calendar; ending a phase early; starting one by hand |
| `lib/discourse_mod_elections/eligibility.rb`, `roll.rb` | Who can run, who can vote, the voter list fixed when nominations open |
| `lib/discourse_mod_elections/nominations.rb`, `voting.rb` | Running, dropping out, disqualifying; casting and taking back a ballot |
| `lib/discourse_mod_elections/publisher.rb`, `seats.rb`, `countback.rb` | Publishing (moderator rights and trust levels), seats left mid-term |
| `lib/discourse_mod_elections/notifier.rb`, `announcer.rb`, `disteleplus.rb` | Notifications, the election's topic, the staff Telegram notices |
| `lib/discourse_mod_elections/presenter.rb`, `state.rb` | JSON for the page, the admin tab and the current user; the cached "election in progress" |
| `app/controllers/discourse_mod_elections/` | `ElectionsController` (`/jtech-elections/…`), `AdminController` (`/jtech-elections/admin/…`) |
| `app/jobs/` | `ModElectionsTick` (every minute), `ModElectionsNotifyVoters` |
| `assets/javascripts/discourse/components/mod-elections-*.gts` | The page, the ballot, running, a candidate, the results |
| `admin/assets/javascripts/discourse/components/mod-elections-admin.gts` | The Mod elections admin tab |
| `dumbcourse/src/views/elections.ts`, `dumbcourse/src/ballot.ts` | The Dumbcourse screen and its ranking helpers |
| `assets/stylesheets/mod-elections.scss`, `themes/jtech/stylesheets/jt-elections.scss` | Core-colour styles; the JTech theme's layer over them |

## An election's life

`scheduled → nominating → voting → closed → published`, or `cancelled` from any of the first four.

`Jobs::ModElectionsTick` runs `Lifecycle.tick` every minute. It creates the calendar's election when a scheduled month starts (once per month, a day's slack each side so a time zone change can't start a second one; never once nominations would already be over; never while another is unfinished), then calls `advance!` on each unfinished election. `advance!` moves it to wherever the clock says, all under `election.with_lock`:

- **nominating:** fixes the voter list (`Roll.snapshot!`: account age, trust level 1+, not suspended, silenced, staged or admin; weight = trust level) and puts the sitting moderators on the ballot.
- **voting:** nothing to compute.
- **reminder:** a day before Vote Week ends, never in its first day (`remind_now?`).
- **closed:** draws the lot seed (`SecureRandom.random_number(2**52)`, under 2⁵³ so it survives JavaScript exactly).

What follows a step (topic posts, notifications, Telegram) runs after the lock is released, one step at a time, each rescued: a failed post can't roll a phase back or leave an election stuck. `State.changed!` clears the cached state and publishes `{ changed: true }` on `/jtech-elections/state` to the `trust_level_0` group (signed-in members), and open elections pages reload.

**Deadlines follow the clock, not just the status.** `Election#taking_nominations?` and `#taking_votes?` compare the dates too, so between a deadline and the next tick nothing gets in. Every write (`run!`, `update_statement!`, `withdraw!`, `cast!`, `clear!`, `disqualify!`, `reinstate!`, `publish!`, `Countback.fill!`) re-checks under the election's lock.

## The count (`Stv`)

Weighted single transferable vote, Droop quota (`floor(total / (seats + 1)) + 1`), surpluses moved by the weighted inclusive Gregory method. All arithmetic is in `Rational`, so nothing is lost to rounding; `Tally.serialize` rounds to four places only for display.

Each round: elect everyone at or over the quota (in order of votes); otherwise move the largest surplus; otherwise exclude the lowest. When two or more candidates have no votes at all and enough others are left to fill the seats, they go out together in one stage. When the continuing candidates are no more than the open seats, they're all elected.

**Ties** are broken by the earliest stage where the tied candidates differed, then by lot (a `Random` seeded from the election's seed, over the ids sorted). Every tie is recorded on the stage it happened in, as `{ purpose, method, among, chosen, decided_at }`:

- `purpose`: `exclusion` (who goes out), `surplus` (whose surplus moves first), `order` (who is listed, and so counted back, first among people elected on equal votes);
- `method`: `earlier_stage` (with `decided_at`, the stage that settled it) or `lot`.

A stored result (`elections.result`, jsonb):

```json
{
  "seats": 3, "quota": 7.0, "total": 24.0, "ballots": 11,
  "outcome": "counted", "seed": 633132630957860,
  "elected": [3, 4, 1], "exhausted": 3.1,
  "candidates": [{ "id": 1, "user_id": 12, "incumbent": false }],
  "stages": [
    {
      "number": 4, "action": "exclusion", "candidate": null, "excluded": [2],
      "tallies": { "1": 6.9, "2": 0.0 }, "exhausted": 2.1, "elected": [],
      "ties": [{ "purpose": "exclusion", "method": "lot", "among": [2, 6], "chosen": 2, "decided_at": null }]
    }
  ]
}
```

`action` is `first`, `unopposed`, `surplus` (`candidate` is whose) or `exclusion` (`excluded` is who). Candidates are stored by id only; `Presenter.result_json` adds each one's username, avatar and (with `enable_names` on) name as the account is now, for the page, the admin tab, the topic post and Telegram. So a renamed account shows its new name, an anonymized one shows anonymized, and a deleted one as "a deleted account".

**Countback** (`Countback.replacement`) counts the same ballots again with the people who left the seat excluded from the start, and takes the first newly elected candidate who can still serve and isn't already a moderator. `fill!` does it under the lock and records the seat on the stored result's `countbacks`.

## Publishing and trust levels (`Seats`)

`Publisher.preview` (a POST: the first one sets `previewed_at`, after which ballots can't be set aside or restored, since two previews either side of that would show what was on the ballot) counts and returns `Seats.plan`: who joins, who stays, who leaves (with their strike, trust level afterwards, and `on_ballot`: false for someone made a moderator after nominations opened), and `problems`: winners who can't serve any more (deleted, admin, suspended, silenced, inactive). `publish!` refuses with `winners_cannot_serve` while there are any; the admin takes them off the ballot and the count moves on.

Publishing, under the lock: grants and revokes moderation (`grant_moderation!` / `revoke_moderation!`, logged with `StaffActionLogger`), locks winners at trust level 4 when `mod_elections_former_mods_keep_tl4` is on, gives a strike to each sitting moderator who ran and lost (`mod_elections_strikes` user custom field) and at `mod_elections_strikes_before_tl3` strikes unlocks them back to trust level 3. Admins are never touched. Then `unlink_ballots!` (below). After the commit: the topic post, notifications and the Telegram notice.

`Seats.vacate!` marks a seat stepped down or removed, under the election's lock (like a countback filling it). Removed for abuse goes straight to trust level 3, unlocked; either way the person leaves any later election's ballot (`Nominations.leave_ballots!`: removed is disqualified with a reason, stepped down is withdrawn). Someone made an admin since keeps their rights and trust level.

Every admin action goes in the staff action log through `StaffLog.log`, which puts the person an entry is about in the log's user column (core's `log_custom` keeps it only as text): `mod_election_create`, `_end_phase`, `_cancel`, `_disqualify`, `_reinstate`, `_void_ballot`, `_restore_ballot`, `_publish`, `_vacate`, `_countback`.

## Privacy

| Data | Who sees it |
| --- | --- |
| A ballot's ranking | Its voter only (`me.ballot` on the page), until results are published. Never in any other JSON, topic post, notification or log (`ranking` is in `filter_parameters`) |
| That someone voted | Its voter; admins only through the address report, and only while the election is closed |
| What became of a ballot (`me.receipt`) | Its voter, once voting has closed: counted, or set aside with the admin's reason |
| Ballot IP addresses | Admins, grouped by address, while the election is closed |
| Weight (trust level when nominations opened) | Its voter |
| Stage tallies, turnout, quota, seed | Everyone, once published |
| Candidate statements, disqualification reasons | Everyone who can see the page |

Notifications carry only the election id, the step and a link. The MessageBus message carries only `{ changed: true }`. The Telegram notice when voting closes says nothing about the count (that chat can include moderators, who are candidates).

**Ballots forget their voters.** A ballot is tied to its account only while the election runs, so nobody votes twice. `Publisher.unlink_ballots!`, when results are published, copies each voter's receipt to their voter-list row (`receipt`, `receipt_reason`), clears the ranking and reason of every ballot set aside (they weren't counted), and clears every ballot's `user_id`, `ip_address` and `voided_by_id` and sets its timestamps to the moment of publishing. What's left is what the count and a countback need: weights and rankings. A cancelled election's ballots are deleted. Until then a database query (Data Explorer, say) can read them: the promise is that the forum's own pages and tools never show who ranked whom, and that after the count nothing links them at all. With very few ballots, the published stages can still give away how individuals voted; that's in the nature of publishing a count.

**Moderators are candidates.** Only an admin's suspension or silence (the system's automatic ones count as an admin's) counts against the clean-record rule for running, so a sitting moderator can't keep a rival off the ballot. A current suspension or silence still stops someone running or voting, whoever gave it; the admin tab lists those a moderator gave a candidate or a voter since nominations opened (`moderator_actions`) so admins can undo any that look like campaigning.

**Deleted accounts.** The foreign keys set `user_id` to null, so a deleted voter's ballot stays and a count can't change after the fact. A deleted candidate shows as "a deleted account"; on a ballot still open (`:user_destroyed` → `Nominations.drop_deleted!`) they're withdrawn, so votes for them move on. Once voting has closed the count is left alone and the admin's preview lists them as a winner who can't serve.

## Requests

- `GET /jtech-elections/current.json` (`?id=` for a past one): anyone who can see the forum. `scheduled` elections are never shown.
- `POST|PUT|DELETE /jtech-elections/:id/candidacy.json`, `PUT|DELETE /jtech-elections/:id/ballot.json`: signed in, from the member's own browser session (no API keys, no impersonation), rate limited (30 a minute, 200 an hour).
- `/jtech-elections/admin/…`: admins only (`AdminConstraint` and `Admin::AdminController`). The reads work with the module off, so an admin can always see what happened; the writes (the preview included, since it fixes the ballots) refuse with `module_off`. The address report and setting ballots aside or back work only while the election is closed, and setting aside only before the first preview.
- Creating an election (the schedule, or an admin by hand) checks for an unfinished one and creates it under one `DistributedMutex`, so two can't both get through.

## Testing

| Spec | What it covers |
| --- | --- |
| `spec/lib/mod_elections_stv_spec.rb` | The count: textbook cases, weights, surpluses, ties of every kind, zero-vote exclusion, unopposed, countback; 300 random elections checked against invariants |
| `spec/lib/mod_elections_lifecycle_spec.rb` | The calendar, time zones and clock changes, every step and its follow-ups, deadlines, reminders, MessageBus |
| `spec/lib/mod_elections_seats_spec.rb` | Publishing, trust levels and strikes, winners who can't serve, seats left mid-term, deleted accounts |
| `spec/lib/mod_elections_notifier_spec.rb` | Notifications (each once per step) and the Telegram notices |
| `spec/requests/mod_elections_spec.rb` | Every endpoint as a visitor, a member, a moderator and an admin; what each sees; rate limits; the current user's summary |
| `spec/system/mod_elections_spec.rb` | Running, ranking with buttons and by dragging, mobile mode, a flip phone, live reload, the admin's preview and publish, ties and the receipt |

Run the system spec's mobile example on its own (`--tag mobile`) in a constrained container. To look at the pages on a dev forum, start an election by hand from the Mod elections tab (or `DiscourseModElections::Lifecycle.create!` in a console) and end each phase early from the tab.
