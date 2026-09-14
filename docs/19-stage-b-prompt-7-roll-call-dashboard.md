# Prompt 7: Roll-Call Views, Dashboard Aggregates, Broadcast

**Document:** 19 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 9 (second half) and item 13 (the query side; Channels themselves come with the routes prompt)
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 13 September 2026

---

## Scope note

Prompt 6 built the engine. This prompt builds the read side on top of it: what a warden sees (FR-ROLL-01, FR-ROLL-06), what the dashboard shows (FR-DASH-01 to FR-DASH-03), and the notification that lets both update live (FR-DASH-05, via PubSub now, Channels later). No routes yet. Nothing in this prompt writes an event; it only reads what Prompt 6 produces, plus one broadcast hook.

Two definitions are decided here because the documents use the words without defining them; both are marked in the prompt and go to DECISIONS.md.

Have Claude Code read `docs/05-srs.md` (FR-ROLL-01, 02, 06; FR-DASH-01..05), `docs/11-wireframes-and-ui-specification.md` sections 1.5 and 2.1, and `docs/10-security-design.md` section 1 (a warden's dashboard visibility is "own zone/area only").

---

## The prompt

```
This is the seventh step in building Salvorion. Prompt 6 (complete)
built the Accountability core. This prompt builds the read side: the
warden's roll-call list, the dashboard aggregates, and a PubSub
broadcast so clients can update live. Nothing here writes an
AccountabilityEvent.

Read docs/05-srs.md (FR-ROLL-01, FR-ROLL-02, FR-ROLL-06, FR-DASH-01 to
FR-DASH-05), docs/11-wireframes-and-ui-specification.md sections 1.5
and 2.1, and docs/10-security-design.md section 1 before starting.

All queries in this prompt must be set-based (joins and GROUP BY), not
loops over people. The dev roster has 1,373 people; the queries must
still be fast at ten times that (NFR-PERF-01/02). Where an index is
missing, add it in a new migration — do not edit the 24 existing ones.

TASK 1: Effective warden assignments
In lib/salvorion/accounts.ex add effective_warden_assignments/2
(user, as_of :: DateTime) → the WardenAssignment rows for that user
whose starts_at <= as_of and (ends_at is nil or ends_at >= as_of),
comparing on dates. "As of" is always the activation's started_at, so a
warden's scope during a drill is fixed at the moment the drill starts
and does not shift if an assignment changes mid-drill.

TASK 2: Scope resolution
In lib/salvorion/accountability.ex (or a submodule
Salvorion.Accountability.Scope) add:
- person_areas/1 — expose the same "a person's areas" logic Prompt 6
  used for expectation (usual_area UNION areas linked to any of the
  person's departments). Reuse, do not duplicate.
- warden_scope/2 (user, activation) → %{zone_ids: [...], area_ids: [...]}
  from the effective assignments: an assignment to a zone contributes
  the zone and every area in it; an assignment to an area contributes
  that area and its zone.
- A person is IN SCOPE for a warden during an activation if:
    (i)  any of person_areas/1 is in scope.area_ids, OR
    (ii) any of the person's events in this activation carries an
         area_id in scope.area_ids or an assembly_point_id whose zone is
         in scope.zone_ids.
  (ii) is what lets a student under "signed_in_only", or a visitor, who
  has no roster location, appear on the list of the warden at the
  assembly point where they actually turned up. Record this definition
  in docs/DECISIONS.md.

TASK 3: The warden's roll-call list (FR-ROLL-01, 02, 06)
- list_roll_call/2 (activation, user) → for a warden:
  {:ok, %{unaccounted: [...], flagged: [...], accounted: [...],
          counts: %{unaccounted: n, flagged: n, present: n, absent: n,
                    excused: n}}}
  over every in-scope person who is expected OR has at least one event
  in this activation. Each row: person_id, id_number, first_name,
  last_name, type, primary department name, usual area name (or nil),
  status, source kind (nil if unaccounted), contradiction_open?
  (boolean), last_event_at (server_timestamp of the latest event or
  nil). Sort each group by last_name, first_name.
  "flagged" = open contradiction (contradicting_event_id set and
  contradiction_resolved_at nil), and a flagged person appears in
  flagged ONLY, not also in accounted.
  A user with no effective assignment → {:error, :no_assignment}.
  A user whose role is osh_officer or admin → {:error, :not_a_warden}
  (they use list_roll_call_for_zone/2 below; keeping the two apart
  means the warden path can never accidentally widen).
- list_roll_call_for_zone/2 (activation, zone_id) — the same shape,
  scoped to one zone, for OSH/admin drill-down from the dashboard. No
  role check here; the route layer will apply the RBAC matrix.
- count_unaccounted_for_warden/2 (activation, user) → integer, the
  FR-ROLL-06 live counter; must be a single COUNT query, not
  list_roll_call/2 with a length.

TASK 4: Dashboard aggregates (FR-DASH-01, 02, 03)
DECISION on definitions (record in docs/DECISIONS.md):
  - A person is attributed to exactly one department for rate purposes:
    their primary_department. Secondary memberships (person_departments)
    do not count toward rates, to avoid double counting. A person with
    no primary department is attributed to a synthetic "(no department)"
    bucket so totals still reconcile.
  - Faculty attribution: staff via primary_department.faculty_id;
    students via programme.faculty_id. Nil → "(no faculty)". (All
    faculties are currently nil in the dev data — the queries must
    still be correct when faculties are later assigned.)
  - participation_rate = present / expected, over expected people only.
    accounted_rate = (present + absent + excused) / expected.
    present_unexpected = people present who were not expected (students
    under signed_in_only, visitors); reported alongside, never in the
    denominator. A department with expected = 0 has rate nil, not 0
    (the dashboard shows "n/a", not "0%", to avoid a department with
    nobody expected looking like total non-compliance).
Functions, each taking an activation_id, each a single query or a small
fixed number of queries (never per-department):
- participation_by_department/1 → [%{department_id, department_name,
  expected, present, absent, excused, unaccounted, present_unexpected,
  participation_rate, accounted_rate}], sorted by department_name.
- participation_by_faculty/1 → same shape keyed by faculty.
- counts_by_zone/1 → per zone: zone_number, assembly_point_name,
  expected, present, absent, excused, unaccounted (attributed via
  person_areas → zones; a person whose areas span two zones is counted
  in both — document this), plus arrivals = number of distinct people
  with a SIGN_IN event whose assembly_point belongs to that zone
  (where people actually turned up, which may differ from where they
  were expected).
- unaccounted_list/2 (activation_id, filters) → rows like Task 3's,
  status unaccounted only, filterable by department_id, faculty_id,
  zone_id, type; sorted by department_name then last_name. This is
  FR-DASH-03.
- activation_summary/1 → %{expected, present, absent, excused,
  unaccounted, present_unexpected, open_contradictions, events,
  arrivals} — the headline cards.

TASK 5: Broadcast (FR-DASH-05 groundwork)
Using Phoenix.PubSub (already started by the app), after the transaction
commits in ingest_event/2 and in resolve_contradiction/3 (Prompt 6),
broadcast on topic "activation:#{activation_id}":
  {:person_status_updated, %{activation_id, person_id, status,
    source_kind, contradiction_open?, zone_ids: [...]}}
where zone_ids are the zones the person is attributed to (Task 2), so
a future Channel can fan out only to wardens of those zones. Also
broadcast {:activation_changed, %{activation_id, status}} from
Activations on start, close and mark_reported. Broadcast strictly after
commit — never from inside the transaction — so a subscriber can never
observe a message for a write that then rolls back. Add
Accountability.subscribe/1 (activation_id) as the public way to
subscribe.

TASK 6: Indexes and query plans
For each of participation_by_department/1, counts_by_zone/1,
unaccounted_list/2 (no filter) and list_roll_call/2, run EXPLAIN
ANALYZE against the dev database with a campus activation started
(1,373 people expected under all_enrolled). Add indexes where a
sequential scan on person_statuses, expected_presences or
department_areas is doing the heavy lifting. Report the plans' top line
and total execution time before and after any index you add.

VERIFICATION
Use the dev roster. Start a campus activation under "signed_in_only"
(162 staff expected). Create three warden users: W5 assigned to Zone 5,
W8 assigned to Zone 8 (Nursing), WA assigned to the single area
"Computer Information Sciences" (Zone 5). All assignments start
yesterday, no end date. After completing all tasks, tell me:

 1. mix compile clean; mix precommit passes; test count.
 2. list_roll_call for W5: counts.unaccounted = 15 (CIS 8 + Stores &
    Transportation 7, from Prompt 6 item 4), flagged 0, accounted 0.
    For WA: unaccounted 8, all CIS. For W8: unaccounted = the number of
    Nursing staff (state it). Show three rows from W5's list.
 3. Scan one CIS staff member (S1) at Zone 5's assembly point. Confirm
    W5 and WA both now show S1 as accounted/present and unaccounted
    down by one; W8 unchanged.
 4. Scan a synthetic STUDENT (T1) at Zone 5's assembly point. Confirm
    T1 appears in W5's accounted list (rule ii) with type student, does
    NOT appear in W8's list, and appears in WA's list only if the
    scan's assembly point resolves into WA's scope — state which it is
    and why.
 5. Roll_call/absent S1 (by W5). Confirm S1 moves to W5's flagged
    group, not accounted, and count_unaccounted_for_warden(W5) is
    unchanged by this (flagged is not unaccounted). Resolve it; confirm
    S1 returns to accounted.
 6. Effective assignments: add an assignment for W8 to Zone 5 with
    ends_at = yesterday. Confirm W8's list is unchanged (expired
    assignments do not apply). Add one starting tomorrow; unchanged
    again.
 7. A warden with no assignment → {:error, :no_assignment}. The seeded
    admin calling list_roll_call → {:error, :not_a_warden}; the same
    admin calling list_roll_call_for_zone(zone 5) → the same rows W5
    sees.
 8. participation_by_department: show the CIS and Stores &
    Transportation rows and one department with expected = 0 (there
    should be none among the 21 under a campus activation — if so,
    demonstrate the nil rate with a zones-scope activation instead, or
    with the "(no department)" bucket). Confirm the sum of expected
    across all rows = 162 and the sum of present = number of scans so
    far.
 9. participation_by_faculty: expect a single "(no faculty)" row with
    expected 162 (explain why, given the dev data).
10. counts_by_zone: show Zones 5 and 8. Confirm Zone 5 arrivals = 2
    (S1 and T1) and Zone 5 expected = 15. State how many people are
    counted in more than one zone and why.
11. unaccounted_list with filter zone_id = Zone 5 → 14 rows (15 minus
    S1). With department_id = Nursing → the Nursing staff count.
12. activation_summary → all fields, and confirm expected + 
    present_unexpected accounts for every person with a status row.
13. PubSub: in a test, subscribe to the activation, ingest a scan,
    assert_receive {:person_status_updated, %{zone_ids: [zone5_id]}}.
    Then wrap an ingest in a transaction that you deliberately roll
    back and refute_receive — proving the after-commit rule.
14. Task 6: the four EXPLAIN ANALYZE top lines and timings, and every
    index added (with its migration filename).
15. Every file created or modified, and the DECISIONS.md text added.

Stop after verification. Do not build routes, Channels, or Visitors.
```

---

## What to check yourself

1. **Item 4 is the one that tests the scope definition rather than the code.** A student under `signed_in_only` has no roster location, so whether they appear on a warden's list depends entirely on rule (ii). Make sure the answer for WA (single-area warden) is reasoned, not assumed: an assembly point belongs to a zone, not an area, so a scan at Zone 5's assembly point puts T1 in Zone 5's scope, and WA's scope includes Zone 5 via the area→zone rule in Task 2. If the report says T1 does not appear for WA, the scope logic contradicts the prompt; if it says T1 appears, it should say why.
2. **Item 13's refute_receive is the half that matters.** Any implementation will pass the assert. Only an after-commit broadcast passes the refute. If Claude Code cannot make the rollback case work in the sandbox, it must say so and explain the mechanism it used instead, not drop the test.
3. **Read the rate definitions in DECISIONS.md as a Dean would.** "Participation" as present/expected means an excused person lowers a department's rate. That is arguably right (they did not participate) and arguably harsh (they were accounted for). It is a presentation decision OSH may want to flip; the numbers to flip it (accounted_rate) are already there. Make sure the note says that.
4. **Item 10's multi-zone count is expected, not a bug.** A department with areas in two zones (Robinson Hall's floors, for instance, once departments are linked there) legitimately makes its staff expected in both. Confirm the report calls this out rather than "fixing" it by picking one zone arbitrarily.
5. **Check the migration for indexes was numbered after 20260908000024** and does not touch the existing 24 files.
