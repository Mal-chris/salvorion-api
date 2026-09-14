# Prompt 5: Activations Context

**Document:** 17 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 8
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 12 September 2026

---

## Scope note

The `Activation` and `ActivationZone` schemas, and their `start_changeset`/`close_changeset`/`mark_reported_changeset`/`schedule_changeset` functions, already exist (fixed during the audit — Document 13, finding 2.1/2.3). This prompt builds the context module around them: the actual `start`/`close` operations, the concurrency-safe zone-overlap guard (FR-ACT-05), and the audit wiring. No routes yet, same as Prompts 3 and 4 — verification via `mix run`.

Have Claude Code read `docs/05-srs.md` (FR-ACT-01 to FR-ACT-06), `docs/08-sequence-state-deployment-diagrams.md` section 5 (the state diagram), and `docs/10-security-design.md` section 1 (note: starting and closing an activation is **OSH Officer only** — this is deliberately narrower than the locations/settings permissions from Prompt 3; System Administrator does not get this one, since declaring an emergency or drill is an operational decision, not a system-configuration one).

---

## The prompt

```
This is the fifth step in building Salvorion. Prompts 1–4 (complete)
built auth, Organisation/Locations, and Roster. This prompt builds the
Activations context: the state machine that governs a drill or real
emergency from scheduling through to being reported.

Read docs/05-srs.md (FR-ACT-01 to FR-ACT-06) and
docs/08-sequence-state-deployment-diagrams.md section 5 before starting.
The Activation and ActivationZone schemas, and their four changesets
(schedule_changeset, start_changeset, close_changeset,
mark_reported_changeset), already exist in
lib/salvorion/activations/activation.ex — do not modify their state
logic, wrap them.

TASK 1: The Activations context — lifecycle operations
Create lib/salvorion/activations.ex exposing:
- schedule_activation/2 (attrs, opts) — creates via schedule_changeset,
  status "scheduled"
- start_activation/2 — creates via start_changeset directly (skipping
  "scheduled" is the common case — most drills and all real emergencies
  start immediately), OR transitions an existing "scheduled" activation
  to "active" if given one. Accept either an attrs map (new) or an
  %Activation{} (existing scheduled one) as the first argument.
- close_activation/2 (%Activation{}, opts) — via close_changeset
- mark_activation_reported/1 (%Activation{}) — via
  mark_reported_changeset, called by the Reporting context once it
  exists (a later prompt) — expose it now so that context has something
  to call
- get_activation!/1, list_activations/1 (filterable by :status,
  :activation_type), get_active_activation_for_zone/1 (zone_id) — the
  currently active activation covering a given zone, whether via direct
  scope or campus-wide, or nil

TASK 2: The zone-overlap guard (FR-ACT-05), made concurrency-safe
"No two active activations can overlap in the same zone" has a
check-then-insert race if implemented as a plain query followed by a
plain insert: two simultaneous start requests could both pass the check
before either commits. Implement it as follows:
- Inside the transaction that creates the activation, take a Postgres
  advisory lock (pg_advisory_xact_lock, released automatically at
  transaction end) keyed by a single fixed integer constant specific to
  "starting an activation". This serialises all start attempts against
  each other — acceptable because starting an activation is a rare,
  low-frequency, human-initiated action, not a hot path; correctness
  matters far more than throughput here.
- Once the lock is held, check for overlap:
  - A new campus-scope activation conflicts with ANY other currently
    active activation, regardless of that other one's scope.
  - A new zones-scope activation conflicts with an existing active
    campus-scope activation (which implicitly covers every zone), OR
    with an existing active zones-scope activation that shares at
    least one zone_id with the new one.
- On conflict, return {:error, :zone_conflict} with a message naming
  which existing activation(s) it conflicts with (id and scope) — do
  not just say "conflict", give enough detail that a caller could show
  a useful error.
- If scope is "zones", validate at least one zone_id was given, and
  that every zone_id given actually exists (a bad id is a validation
  error, not something that reaches the database as an orphaned
  activation_zones row).

TASK 3: Audit integration
Every lifecycle transition (schedule, start, close, mark_reported) is
audited via the existing Salvorion.Audit.Multi pattern
(action: "activation.scheduled" / "activation.started" /
"activation.closed" / "activation.reported"). Include activation_type
and scope in the audit "after" payload so the history is readable
without a join.

TASK 4: Authorisation note (do not implement yet — no routes exist)
Record in docs/DECISIONS.md: starting and closing an activation is
OSH Officer only, not System Administrator (Document 10, section 1).
This differs from the Locations/Organisation/Settings permissions from
Prompt 3, where OSH Officer and Administrator are both permitted. Flag
this so whoever wires the RBAC route mapping in the routes prompt does
not default to "same as everything else OSH Officer can do."

VERIFICATION
After completing all tasks, tell me explicitly:
1. mix compile output, zero new warnings; mix precommit passes.
2. Full lifecycle test, narrated: schedule_activation -> start_activation
   (on the scheduled one) -> close_activation -> mark_activation_reported.
   Show the status after each step.
3. Start a campus-wide activation, then attempt to start a second
   (zones-scope, any zone) while the first is still active. Confirm
   {:error, :zone_conflict} with the first activation's id in the
   message. Close the first, then confirm the second now starts
   successfully.
4. Start a zones-scope activation for zone A only. Confirm a second
   zones-scope activation for zone B (no overlap) starts successfully
   at the same time. Then attempt a third for zone A again and confirm
   it is rejected.
5. Demonstrate the concurrency guard actually guards something: spawn
   two concurrent Elixir processes both calling start_activation for
   the same zone at approximately the same moment. Confirm exactly one
   succeeds and one receives {:error, :zone_conflict} — not two
   successes, and not a database error from a race. Explain what
   would have happened without the advisory lock.
6. Attempt close_activation on an activation that is not "active"
   (e.g. one already closed) and confirm it is rejected with a clear
   error, not a silent no-op.
7. Show the audit_logs rows for one full lifecycle (the Task 2 test),
   confirming actor_user_id is populated (not nil — these are always
   user-initiated, unlike the Prompt 3 seed).
8. A list of every file created or modified.

Stop after verification. Do not build routes/controllers, and do not
start the Accountability context yet.
```

---

## What to check yourself

1. **Item 5 is the one that matters most in this entire prompt.** A guard that "looks correct" in single-threaded testing (items 3 and 4) can still have a race condition invisible until two requests genuinely overlap in time. Read Claude Code's explanation of what would happen without the advisory lock carefully — if it can't articulate the specific race (both transactions reading "no active activation in this zone" before either commits), that's a sign the lock was added cosmetically rather than understood.
2. **Confirm the lock is scoped correctly.** A single fixed advisory-lock key serialises *every* activation start against every other, campus-wide, one at a time, which is the right trade for this system (starting an activation is rare) but worth being aware of as a deliberate simplicity choice, not an accident — a system starting hundreds of activations per second elsewhere would need a differently-scoped lock, but that's not this system.
3. **Read the zone_conflict error messages yourself** (items 3 and 4) and confirm they'd actually be useful to an OSH Officer seeing them in a future UI, not just useful to you as a developer reading a stack trace.
4. **Check docs/DECISIONS.md actually got the OSH-Officer-only note added** (Task 4) — this is a small thing that's cheap to verify and easy for a future prompt to get wrong if it's not sitting there as a reminder.
