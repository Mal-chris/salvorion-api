# Prompt 6: Accountability Core

**Document:** 18 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 9 (first half). The roll-call views, counts and real-time broadcast are Prompt 7; visitors are Prompt 8. Accountability was always the piece most likely to split in two, and it has.
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 12 September 2026

---

## Why this one is different

Everything built so far has been CRUD plus seed data. This prompt builds the event-sourced engine at the centre of the system: events are appended, never changed; a person's status is *derived* from their events by a precedence rule; and the one real conflict (a scan says present, a roll call says absent) is resolved by rule and flagged for a human. Every later feature, the dashboard, the roll-call screen, the report, reads from what this prompt produces. It is worth reading the prompt in full before pasting it, because several rules in it are decisions I have made on your behalf where the documents left room; they are marked, and they are all cheap to change now and expensive to change later.

Have Claude Code read `docs/05-srs.md` (FR-SIGN-*, FR-ROLL-*, FR-ROS-05), `docs/06-erd-and-data-dictionary.md` (AccountabilityEvent, PersonStatus, ExpectedPresence), `docs/08-sequence-state-deployment-diagrams.md` sections 1–3, and `docs/03-technical-foundation.md` section 2.1 before starting.

---

## The prompt

```
This is the sixth step in building Salvorion, and the most important one:
the Accountability core. Prompts 1–5 (complete) built auth,
Organisation/Locations, Roster (with 1,370 synthetic people across the
real departments), and Activations with its state machine.

Read, before starting: docs/05-srs.md (FR-SIGN-01..07, FR-ROLL-01..07,
FR-ROS-05), docs/06-erd-and-data-dictionary.md (the AccountabilityEvent,
PersonStatus and ExpectedPresence entities and section 2's notes),
docs/08-sequence-state-deployment-diagrams.md sections 1–3, and
docs/03-technical-foundation.md section 2.1. The three schemas already
exist in lib/salvorion/accountability/. Follow the audit pattern
(Salvorion.Audit.Multi) for every write.

The invariants this prompt must never violate:
  (I1) AccountabilityEvent rows are append-only. No code path updates or
       deletes one. Ever.
  (I2) server_timestamp is set by the server at ingest and is the only
       timestamp used for ordering. client_timestamp is recorded but
       never trusted for ordering.
  (I3) client_uuid is the idempotency key. Ingesting an event whose
       client_uuid already exists returns the existing event and writes
       nothing (FR-SIGN-06).
  (I4) PersonStatus is derived. It can always be rebuilt from the events
       for that (activation, person) and must never hold information that
       is not recoverable from them plus ExpectedPresence.

TASK 1: A minimal Settings context
Accountability needs to read the student accountability rule. Create
lib/salvorion/settings.ex with get_setting/2 (key, default) and
put_setting/3 (key, value, opts) — the latter audited. Seed nothing;
the default passed by the caller is the Release 1 default. The keys and
their documented values are in lib/salvorion/settings/setting.ex's
moduledoc.

TASK 2: Extend the event kinds with "override" (small, deliberate
schema change)
FR-ROLL-07 (added during the audit) lets an OSH Officer or Administrator
override a person's status with a mandatory note. The schema's @kinds
list in lib/salvorion/accountability/accountability_event.ex has no
kind for this. Add "override" to @kinds. The column is a validated
string with no database-level check constraint, so no migration is
needed. In create_changeset/2, require :note when kind is "override".
Update docs/06-erd-and-data-dictionary.md's ACCOUNTABILITY_EVENT entry
(the kind list) to match. Do not add any other kinds.

TASK 3: Expected presence, computed at activation start
Create the function Accountability.initialise_for_activation/1
(activation) and wire it into Activations.start_activation/2 so that it
runs inside the same transaction, immediately after the activation
becomes active. It must be idempotent (running it twice for the same
activation must not duplicate rows — the unique index on
expected_presences (activation_id, person_id) is the backstop; check
first rather than relying on it).

It computes the set of expected people and, for each, inserts:
  - an ExpectedPresence row (rule_applied = the rule name below), and
  - a PersonStatus row with status "unaccounted", source_event_id nil.
Materialising "unaccounted" rows up front (rather than computing them
lazily) is deliberate: it makes every later count a GROUP BY on
person_statuses, and it gives PowerSync a concrete row per expected
person to replicate to wardens.

The expectation rules for Release 1 — DECISIONS I have made where the
documents left room; implement exactly these and record them in
docs/DECISIONS.md so OSH can confirm or change them later:

  Staff (Person.type == "staff"):
    - campus-scope activation: every staff person is expected.
    - zones-scope activation: a staff person is expected if ANY of their
      "areas" lies in one of the activation's zones. A person's areas =
      their usual_area (if set) UNION every area linked (via
      department_areas) to any of their departments (primary_department
      plus person_departments). rule_applied = "staff_by_location".
  Students (Person.type == "student"), by the setting
  "student_accountability_rule" (default "signed_in_only"):
    - "signed_in_only": no student is expected in advance. A student who
      signs in is counted as present (a PersonStatus row is created on
      their first event) but never appears as unaccounted.
      rule_applied is not recorded for students under this rule since no
      ExpectedPresence row is created.
    - "all_enrolled": every student is expected, regardless of scope
      (students have no location data yet, so a zones-scope activation
      over-counts under this rule — record this as a known Release 1
      limitation in docs/DECISIONS.md). rule_applied = "all_enrolled".
    - "timetable_expected": not implemented in Release 1; if the setting
      holds this value, raise a clear error at activation start naming
      the unsupported rule rather than silently falling back.
  Visitors: never expected in advance. Their first event creates their
  PersonStatus row.
  Synthetic vs real: expectation is computed over every Person regardless
  of source. (Synthetic data is only present in dev/test databases.)

TASK 4: Event ingest
Create Accountability.ingest_event/2 (attrs, opts) — the single entry
point for every sign-in, roll-call mark, visitor registration and
override, whether from a live request or from an offline queue being
uploaded later.

Input: a map with client_uuid, activation_id, kind, status,
recorded_by_id, client_timestamp, and EITHER person_id OR id_number
(resolve id_number via Roster.get_person_by_id_number/1; if it resolves
to nothing return {:error, :unknown_person} and write nothing — an
unknown card is not an event). Optional: device_id, assembly_point_id,
area_id, note.

Rules, in order:
  a. If an event with this client_uuid exists, return
     {:ok, existing_event, :duplicate}. Write nothing. (I3)
  b. The activation must not be "scheduled" → {:error, :activation_not_started}.
  c. Late events (offline clients uploading after the activation closed)
     — DECISION: accept an event for a closed or reported activation if
     its client_timestamp is no later than closed_at plus a tolerance of
     5 minutes (a constant, documented, to be made a setting later if
     needed). Reject otherwise with {:error, :activation_closed}. Accept
     means: the event is stored and status re-derived exactly as if it
     had arrived on time; additionally, if the activation's status is
     "reported", write an audit row with action
     "accountability.late_event_after_report" so the Reporting context
     can later offer a regenerate (FR-REP-05). Record this rule in
     docs/DECISIONS.md.
  d. For kind "override": recorded_by must be a user whose role is
     osh_officer or admin (check the user record here — the RBAC plug
     does not exist for this route yet, and this rule must hold even for
     internal callers). Otherwise {:error, :override_not_permitted}.
  e. Insert the event via create_changeset/2 (which sets
     server_timestamp). Then, in the same transaction, re-derive
     PersonStatus for (activation_id, person_id) per Task 5 and upsert
     it. Audit action: "accountability.event_ingested" with the event's
     kind and status in the payload.
  f. Return {:ok, event, person_status}.

Concurrency: two events for the same person can arrive at the same
moment from two devices (two wardens scanning the same person). Both
events must be stored (I1) and exactly one PersonStatus row must result.
Take a Postgres advisory transaction lock keyed on a hash of
(activation_id, person_id) before deriving and upserting, so
derivations for the same person serialise while different people
proceed in parallel. (This is a per-person lock, unlike the single
global lock used for starting activations.)

TASK 5: Status derivation — the precedence rule
Create Accountability.derive_status/2 (activation_id, person_id) as a
PURE function of the events for that pair (plus whether an
ExpectedPresence row exists), returning the attrs for the PersonStatus
row. It must be callable at any time to rebuild the row (I4). Also
expose rebuild_person_status/2, which derives and upserts, and
rebuild_activation_statuses/1, which does it for every person with
events or an expectation in the activation (for repair, and for the
verification below).

Kinds are grouped:
  SIGN_IN   = scanned, manual, visitor_registered   (always status present)
  ROLL_CALL = roll_call                              (present | absent | excused)
  OVERRIDE  = override                               (present | absent | excused)

Precedence, highest first:
  1. If any OVERRIDE event exists: status = the latest override's status;
     source_event_id = that event. Any contradiction is considered
     resolved (contradiction_resolved_at = that override's
     server_timestamp) and contradicting_event_id is kept for history.
  2. Else if any SIGN_IN event exists: status = present;
     source_event_id = the latest SIGN_IN event.
     Contradiction check: let R = the latest ROLL_CALL event. If R exists
     and R.status is absent or excused, then a contradiction is open:
     contradicting_event_id = R, and contradiction_resolved_at = nil —
     UNLESS the existing PersonStatus row already has
     contradicting_event_id == R and a non-nil contradiction_resolved_at
     (the warden already confirmed this exact contradiction), in which
     case preserve both fields. Order of arrival does not matter: a
     roll-call "absent" followed by a scan, or a scan followed by a
     roll-call "absent", produce the same result (FR-ROLL-05).
     A ROLL_CALL event with status present, or a later ROLL_CALL that
     supersedes an earlier absent, means no open contradiction.
  3. Else if any ROLL_CALL event exists: status = the latest roll_call
     event's status; source_event_id = that event. No contradiction.
  4. Else (no events): status = "unaccounted" if an ExpectedPresence row
     exists; otherwise no PersonStatus row at all (return :none).

"Latest" always means greatest server_timestamp (I2), with id as a
deterministic tiebreak.

TASK 6: Resolving a contradiction
Create Accountability.resolve_contradiction/3 (activation_id, person_id,
opts) — sets contradiction_resolved_at = now on the PersonStatus row,
leaves status and contradicting_event_id unchanged, audited with action
"accountability.contradiction_resolved". This is the warden's "confirm"
action from Document 11, section 1.5. It does not create an event
(nothing about the person changed; the warden acknowledged the system's
resolution). If no open contradiction exists, return
{:error, :no_open_contradiction}.

TASK 7: Minimal count primitives (the dashboard proper is Prompt 7)
- count_statuses/1 (activation_id) → %{present: n, absent: n,
  excused: n, unaccounted: n}
- count_open_contradictions/1 (activation_id)
- count_events/1 (activation_id)
- list_events_for_person/2 (activation_id, person_id), ordered by
  server_timestamp — the audit view of one person's history

VERIFICATION
Use an activation started against the existing synthetic roster
(campus scope, default rule "signed_in_only"), with the seeded admin
(role admin) as the recording user unless stated otherwise. After
completing all tasks, tell me explicitly:

 1. mix compile output, zero new warnings; mix precommit passes; total
    test count.
 2. Expectation, rule "signed_in_only", campus scope: after
    start_activation, report count of expected_presences rows and of
    person_statuses rows with status unaccounted. Both should equal the
    number of staff (150 synthetic + any roster-sourced staff from the
    Prompt 4 fixture). Confirm zero students are expected.
 3. Expectation, rule "all_enrolled": put_setting the rule, start a
    second activation (after closing the first — the zone guard), and
    report the same counts. Expected = all staff + all students.
    Then restore the setting to "signed_in_only".
 4. Expectation, zones scope, rule "signed_in_only": close the second
    activation; start a zones-scope activation for Zone 5 only
    (Campbell's Sports Centre Greens). Report how many staff are expected
    and confirm every one of them belongs to a department linked to an
    area in Zone 5 (Gymnatorium, Field View Building, Computer
    Information Sciences, Stores & Transportation) — list the departments
    represented. Confirm a staff member from, say, Nursing (Zone 8) is
    NOT expected. Close it and start a fresh campus-scope activation for
    the remaining tests.
 5. Idempotency (I3): ingest the same scanned event twice (same
    client_uuid). Confirm one row in accountability_events, the second
    call returned :duplicate, and PersonStatus is present.
 6. Second distinct scan (FR-SIGN-06): ingest a second scanned event for
    the same person with a new client_uuid. Confirm two event rows,
    status still present, no contradiction.
 7. Contradiction, scan first: for person P1, ingest scanned/present,
    then roll_call/absent. Confirm status present,
    contradicting_event_id = the roll_call event,
    contradiction_resolved_at nil, count_open_contradictions = 1.
 8. Contradiction, roll call first: for person P2, ingest
    roll_call/absent, then scanned/present. Confirm the identical outcome
    to item 7 (order does not matter).
 9. Roll-call correction: for person P3, roll_call/absent then
    roll_call/present. Confirm status present, no contradiction (a
    warden correcting themselves is not a contradiction).
10. Resolve: call resolve_contradiction for P1. Confirm
    contradiction_resolved_at set, status still present,
    count_open_contradictions = 1 (P2 still open). Call it again for P1
    and confirm {:error, :no_open_contradiction}.
11. Re-flag after resolve: for P1, ingest a NEW roll_call/absent (new
    client_uuid). Confirm the contradiction is open again with
    contradicting_event_id = the new event and resolved_at nil.
12. Override: as the admin, ingest override/excused for P2 with a note.
    Confirm status excused, source_event_id = the override,
    contradiction_resolved_at set. Then attempt an override WITHOUT a
    note and confirm the changeset rejects it. Then attempt an override
    recorded_by a user with role warden (create one) and confirm
    {:error, :override_not_permitted}.
13. Unknown person: ingest with id_number "NOPE-000" and confirm
    {:error, :unknown_person} and no event row.
14. Not started: ingest against a scheduled activation and confirm
    {:error, :activation_not_started}.
15. Late events: close the activation. Ingest an event with
    client_timestamp = closed_at + 2 minutes → accepted, status derived.
    Ingest one with client_timestamp = closed_at + 10 minutes →
    {:error, :activation_closed}. Then mark the activation reported and
    ingest one with client_timestamp = closed_at + 1 minute → accepted,
    and confirm an audit row with action
    "accountability.late_event_after_report" exists.
16. Rebuild (I4): pick P1. Record its PersonStatus row. Delete the row
    directly with Repo (test-only; this is the one place a PersonStatus
    is ever deleted, to prove it is derivable). Call
    rebuild_person_status/2. Confirm the rebuilt row is field-for-field
    identical (status, source_event_id, contradicting_event_id,
    contradiction_resolved_at) — EXCEPT explain what happens to
    contradiction_resolved_at, since that field records a human action
    not present in the event log: state plainly whether it survives a
    rebuild, and if it does not, say so as a known limitation of I4 and
    record it in docs/DECISIONS.md rather than hiding it.
17. Concurrency: two concurrent processes on separate DB connections
    (the same sandbox technique as Prompt 5) ingest two different
    scanned events for the same person at the same moment. Confirm two
    event rows and exactly one PersonStatus row, status present, no
    error. Explain why the per-person advisory lock, not the unique
    index alone, is what makes this safe.
18. count_statuses/1 for the final activation, and the per-person event
    history for P1 from list_events_for_person/2.
19. Every file created or modified, and the exact text added to
    docs/DECISIONS.md and docs/06-erd-and-data-dictionary.md.

Stop after verification. Do not build the roll-call views, PubSub
broadcasts, routes, or the Visitors work — those are the next prompts.
```

---

## What to check yourself

1. **Item 16 is the one to read most carefully.** `contradiction_resolved_at` is a record of a human decision (the warden pressed "confirm"), and there is no event for it, so a rebuild from events alone *cannot* restore it. That is a real, small hole in invariant I4. The honest answers are either "yes, it is lost on rebuild; rebuild is a repair tool, not a routine path, and the resolution is still in the audit log" (acceptable for Release 1, must be written down) or "I changed the design so the resolution is itself an event" (better, but a bigger change than this prompt asked for). What you must not accept is a report that skips the question or claims the field survives without explaining how.
2. **Items 7 and 8 must produce identical results.** If they do not, the precedence rule has been implemented as order-dependent, which is exactly the bug FR-ROLL-05 exists to prevent. Compare the two outputs field by field, not just "both say present."
3. **Item 4's department list is your check on the two-hierarchy design.** Every department it lists should be one linked to a Zone 5 area in Prompt 3's seed. If a department appears that is not linked to any of those four areas, the location expectation logic is walking the wrong join.
4. **Read the DECISIONS.md additions as if you were OSH.** The staff-by-location rule, the 5-minute late window, and the all_enrolled over-count are all decisions OSH may want to change. Each should be stated as a decision with its reason, not as a fact of the system.
5. **Do not skip the concurrency item (17) because item 5 in Prompt 5 already covered locking.** This lock is scoped differently (per person, not global) and a mistake in the hash key would let two people's derivations block each other, or worse, not block the same person's.
