# Prompt 8: Visitors and the Retention Purge

**Document:** 20 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 10; also completes Stage A item 2's Oban setup, which has been deferred until something needed a job
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 13 September 2026

---

## Scope note

Visitors are the third population (Charter, section 4.1). They have no roster record, are registered on the spot, get a temporary pass, are counted like everyone else during an activation (FR-VIS-03), and their personal details are purged after a retention period (FR-VIS-04, NFR-PRIV-01). This prompt is also where Oban is configured for the first time, since the purge is the first background job.

One design decision is made here and marked: the visitor's pass code is stored in `Person.id_number`, so a visitor's pass scans through exactly the same path as a staff ID card. The ERD note that `id_number` is "nullable for visitors" becomes "holds the pass code for visitors"; the prompt has Claude Code update Document 06 accordingly.

Have Claude Code read `docs/05-srs.md` (FR-VIS-01..04, FR-SIGN-01), `docs/10-security-design.md` sections 2 and 6, and `docs/09-business-process-models.md` section 2.

---

## The prompt

```
This is the eighth step in building Salvorion. Prompts 1–7 (complete)
built everything through the roll-call and dashboard reads. This prompt
adds visitors and the retention purge, and configures Oban for the
first time.

Read docs/05-srs.md (FR-VIS-01 to FR-VIS-04), docs/10-security-design.md
sections 2 and 6, and docs/09-business-process-models.md section 2
before starting. Follow the Audit.Multi pattern for every write. Recall
from the Prompt 7 follow-up that ingest_event/2 must never be called
inside an enclosing transaction.

TASK 1: Oban setup (first use)
- Add the Oban migration (Oban.Migration up/down) as a new migration
  file numbered after 20260912000001. Do not touch existing migrations.
- Configure Oban in config/config.exs: repo Salvorion.Repo, queues
  [maintenance: 2, reports: 2] (reports is for the later Reporting
  context; define it now so its name is settled), plugins
  [Oban.Plugins.Pruner, {Oban.Plugins.Cron, crontab: [...]}] with the
  purge job (Task 4) scheduled daily at 02:00 UTC.
- Add Oban to the application supervision tree.
- Configure config/test.exs with Oban in testing: :manual mode so jobs
  never run on their own in tests and can be asserted with
  Oban.Testing.
- Confirm mix ecto.migrate applies the Oban tables and that
  mix phx.server boots with Oban running (show the log line).

TASK 2: Visitor registration
In lib/salvorion/roster.ex (visitors are people; keep them in the
Roster context rather than a new one) add:
- register_visitor/2 (attrs, opts) where attrs has first_name,
  last_name, visitor_host (free text: who they are visiting), phone
  (optional), email (optional), visitor_expires_at (a Date; default
  today), and opts may carry activation_id, assembly_point_id, area_id,
  device_id, recorded_by_id.
  It creates a Person with type "visitor", source "visitor_registration",
  and — DECISION — id_number set to a generated pass code of the form
  "VIS-" followed by 8 characters from Crockford base32 (no I, L, O, U),
  generated with :crypto.strong_rand_bytes. Retry on the (astronomically
  unlikely) unique-index collision. Record in docs/DECISIONS.md and
  change docs/06-erd-and-data-dictionary.md's PERSON id_number note from
  "nullable for visitors" to "pass code for visitors (VIS-xxxxxxxx)".
  The pass code is the QR payload: the client renders it as a QR; a
  scan of it resolves through Roster.get_person_by_id_number/1 exactly
  like a staff card (FR-SIGN-01), with no special visitor path.
  Audit action "visitor.registered" with the pass code and host in the
  payload.
- If opts[:activation_id] is given (registration at an assembly point
  during an activation, per docs/09 section 2), then AFTER the person's
  transaction commits, call Accountability.ingest_event/2 with kind
  "visitor_registered", status "present", the new person_id, a fresh
  client_uuid (or opts[:client_uuid] if the client supplied one, for
  offline idempotency), client_timestamp now (or opts value), and the
  assembly_point_id/area_id/device_id/recorded_by_id from opts. Return
  {:ok, person, event_or_nil}. If the ingest fails (e.g. the activation
  has closed), the person still exists — return {:ok, person,
  {:error, reason}} so the caller can tell the warden; do not roll the
  registration back.
- visitor_pass/1 (person) → %{pass_code, first_name, last_name,
  visitor_host, visitor_expires_at} — what the client shows on the pass
  screen (docs/11 section 1.4).
- list_visitors/1 (opts: :active_on Date, default today) → visitors
  whose visitor_expires_at >= that date, newest first.

An expired pass that is scanned during an activation is still accepted
(the person is physically present; that is the fact that matters) —
document this in DECISIONS.md; a future client can show a warning.

TASK 3: Purge semantics
Add Roster.purge_expired_visitors/1 (opts, actor nil by default —
this is a system action):
- retention_days = Settings.get_setting("visitor_retention_days", 90)
- Select visitors where visitor_expires_at + retention_days < today.
- For each (one UPDATE per row inside one transaction is fine at this
  scale; a single UPDATE ... WHERE is better — use it): set first_name
  "Visitor", last_name "(purged)", email nil, phone nil,
  visitor_host nil. Keep id_number (the pass code is not personal data
  and preserves the link from old events to a row). Keep the row itself:
  accountability_events and person_statuses reference it, and FR-VIS-04
  purges personal details, not history.
- One audit row for the run: action "visitor.purged", actor nil,
  after: %{count: n, retention_days: d, cutoff: date}. Do not write one
  audit row per visitor (that would re-record who they were).
- Return {:ok, count}.

TASK 4: The purge job
Create lib/salvorion/roster/workers/purge_visitors_worker.ex, an
Oban.Worker on the :maintenance queue, unique per day (Oban's unique
option, period 24h) so the cron cannot enqueue two runs for one day,
calling purge_expired_visitors/1 and returning :ok. Wire it into the
Cron crontab from Task 1.

VERIFICATION
After completing all tasks, tell me explicitly:
 1. mix compile clean; mix precommit passes; test count.
 2. mix ecto.migrate output for the Oban migration, and the
    mix phx.server log line showing Oban started with the two queues.
 3. Register a visitor with no activation. Show the person row (type,
    source, id_number matching ^VIS-[0-9A-HJKMNP-TV-Z]{8}$,
    visitor_expires_at = today) and visitor_pass/1's output.
 4. Start a campus activation (signed_in_only) and register a visitor at
    Zone 5's assembly point, recorded by a warden assigned to Zone 5.
    Confirm: the visitor_registered event exists with status present;
    the visitor appears in that warden's list_roll_call accounted group
    (type visitor, via scope rule ii); activation_summary's
    present_unexpected is 1 and arrivals is 1.
 5. Scan the same visitor's pass code (a scanned event with id_number =
    the pass code). Confirm it resolves to the same person, two events
    exist, status still present, no contradiction.
 6. Close the activation, wait past nothing (use client_timestamp =
    closed_at + 10 minutes), register a visitor with that activation_id.
    Confirm the person is created and the return is
    {:ok, person, {:error, :activation_closed}}.
 7. Purge: create three visitors directly with visitor_expires_at of
    100 days ago, 91 days ago, and 89 days ago. Run
    purge_expired_visitors/1. Confirm the first two are anonymised
    (names "Visitor" "(purged)", contact nil, id_number retained) and
    the third is untouched; {:ok, 2}; exactly one visitor.purged audit
    row with count 2 and nil actor. Confirm the anonymised people's
    person_statuses/events from item 4 (if any of them were the item 4
    visitor — make one of them be) are still present and still resolve
    to the row.
 8. Purge idempotency: run it again immediately; {:ok, 0} and a second
    audit row with count 0.
 9. Retention setting: put_setting visitor_retention_days to 30, create
    a visitor expired 31 days ago, run the purge, confirm it is
    anonymised; restore the setting to 90.
10. Oban: show the crontab entry; in a test with Oban in :manual mode,
    assert_enqueued for the worker after simulating the cron (or
    directly insert the job) and perform_job returning :ok; show the
    unique option and demonstrate that inserting the job twice in one
    day yields one job.
11. Every file created or modified, and the DECISIONS.md and docs/06
    text changed.

Stop after verification. Do not build routes or the Reporting context.
```

---

## What to check yourself

1. **Item 7's "history survives the purge" is the point of the whole design.** A purged visitor must still be countable in old activations and reports (they were there; that is compliance history), while nothing personal about them remains. Confirm the events and status rows still point at the row and that the row no longer says who they were.
2. **The purge audit row must not undo the purge.** One row per run with a count, never one per visitor with a name. If you see a per-visitor audit row, the purge has leaked the data it was deleting into a table that is never deleted.
3. **Check the pass-code regex yourself against a few generated codes.** Crockford base32 excludes I, L, O and U so codes are unambiguous when read aloud or typed manually at the fallback screen (FR-SIGN-02). If a generated code contains any of those letters, the alphabet is wrong.
4. **Item 6 is the offline-visitor case.** A warden registering a visitor from a queue that uploads after the drill has ended should still get the person created (so the pass they printed is valid) and a clear reason why the accountability event was refused. Both halves matter.
5. **Look at the Oban config once yourself.** The cron time is 02:00 UTC, which is 21:00 Jamaica time the previous evening. That is fine, but it is a decision; if OSH would rather the purge run at a Jamaican hour, it is one line to change and worth knowing where.
