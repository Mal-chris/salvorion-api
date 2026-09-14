# Decisions and notes for upcoming work

Recorded during project scaffolding so they are not lost. Each section names
the prompt that implemented it, or says it is pending.

## Guardian must use an asymmetric signing key (RS256 or ES256) (Prompt 2)

Do **not** use Guardian's default HS512 shared secret. PowerSync authenticates
clients by verifying their JWT against a JWKS endpoint that Phoenix will expose
at `/.well-known/jwks.json`. A symmetric key cannot be published as a JWKS
(publishing it would let anyone forge tokens), so tokens must be signed with an
RSA or EC private key and the matching public key served from that endpoint.
The PowerSync service config (`docker/powersync/powersync.yaml`) already points
`client_auth.jwks_uri` at that URL via `POWERSYNC_JWKS_URL`.

## Client offline outbox via PowerSync upload queue (pending, Stage C)

The Flutter client uses PowerSync's upload queue as its offline outbox. The
client's PowerSync connector POSTs queued writes to this API, including a
client-generated `client_uuid` on each write for idempotency. The write
endpoints must therefore treat `client_uuid` as an idempotency key and return
success for replays of an already-applied write.

## Roster (Prompt 4): synthetic ID generation is not safe under concurrent runs

The synthetic roster provider numbers `SYN-`-prefixed `id_number`s from the
current maximum already in the table. Two synthetic-generation runs
executing at the same instant could both read the same maximum and assign
the same `id_number` to two different generated people; since
`upsert_person_by_id_number/2` matches on `id_number`, the second run's
write would then overwrite the first run's person rather than fail or
duplicate. Accepted as-is: this is a dev-only tool, run by one person at a
time, not a production data path. Not something to fix unless synthetic
generation is ever automated or run concurrently.

## Starting/closing an activation is OSH Officer only, not System Administrator

Per Document 10 (Security Design), section 1: the RBAC matrix lists "Start
an activation" and "Close an activation" as **OSH Officer only** — the
System Administrator column is blank for both rows. This is a different
shape from the Locations permissions built in Prompt 3 ("Manage assembly
points, zones, areas": Yes/Yes) and the Settings permissions ("Change
system settings": Yes/Yes — the `Setting` schema and context were built in
Prompt 6, but the enforced RBAC row and its route date to Prompt 9's
`SettingController`, per "a settings API route, closing finding 3.6" below),
where OSH Officer and System Administrator are both permitted. **Correction:
Organisation management is not part of this same-shape group** (an earlier
draft of this entry lumped it in) — "Manage departments, faculties,
programmes" is Yes/No/No/No, System-Administrator-only, which is its own
asymmetry, not the Locations/Settings one. Whoever wires the RBAC route
mapping for the Activations routes (a later prompt) must not default to
"same access as everything else OSH Officer can do" — System Administrator
does not get a pass on starting or closing an activation, even though it
does on almost every other OSH-managed resource (Locations, Settings), and
separately has no pass on Organisation management either, for the opposite
reason: that one is the resource OSH Officer itself lacks write access to.

## Settings (Prompt 6): audit rows for settings carry the key in the payload

`Salvorion.Settings.Setting` has a string `key` as its primary key, not a
uuid — there is no `id` to hang an `entity_id` on. `put_setting/3` therefore
writes its audit row via `Audit.record/1` directly, with `entity_id: nil`
and the setting's `key` carried in the `after` (and `before`) payload
instead, rather than going through the `Salvorion.Audit.Multi.audit/7`
convention every other context uses (which assumes the changed entity has
an `id`). A caller looking up a setting's audit history filters
`Audit.list_audit_logs/1` by `entity_type: "setting"` and reads the key out
of the payload, not by `entity_id`.

## Accountability core (Prompt 6): expectation rules for Release 1

Implemented in `Salvorion.Accountability.initialise_for_activation/1`, run
inside the transaction that makes an activation active. Recorded here so OSH
can confirm or change them; none of these were fixed by the documents.

- **Staff** (`Person.type == "staff"`). Campus-scope activation: every staff
  person is expected. Zones-scope activation: a staff person is expected if
  any of their areas lies in one of the activation's zones, where a person's
  areas are their `usual_area` (if set) plus every area linked through
  `department_areas` to any of their departments (`primary_department` plus
  `person_departments`). `rule_applied = "staff_by_location"`.
- **Students** (`Person.type == "student"`), by the setting
  `"student_accountability_rule"` (default `"signed_in_only"`):
  - `"signed_in_only"`: no student is expected in advance. A student who
    signs in is counted present (their first event creates their
    `PersonStatus` row) but never appears as unaccounted. No
    `ExpectedPresence` row is written for students under this rule.
  - `"all_enrolled"`: every student is expected regardless of scope.
    **Known Release 1 limitation:** students carry no location data yet, so
    a zones-scope activation under this rule over-counts — every student is
    expected even in a two-zone drill. `rule_applied = "all_enrolled"`.
  - `"timetable_expected"`: not implemented in Release 1. If the setting
    holds this value, starting an activation raises an `ArgumentError`
    naming the unsupported rule rather than silently falling back.
- **Visitors**: never expected in advance; their first event creates their
  `PersonStatus` row.
- **Synthetic vs real**: expectation is computed over every `Person`
  regardless of `source`. Synthetic people exist only in dev/test databases.
- "Unaccounted" rows are materialised up front (one `PersonStatus` per
  expected person) rather than computed lazily, so every later count is a
  `GROUP BY` on `person_statuses` and PowerSync has a concrete row per
  expected person to replicate to wardens.

## Accountability core (Prompt 6): late events after an activation closes

`Accountability.ingest_event/2` treats two classes of event differently once
an activation is `closed` or `reported`. Both are still rejected on a
`scheduled` activation (`{:error, :activation_not_started}`).

- **Field events** — kinds `scanned`, `manual`, `visitor_registered` and
  `roll_call`. These come from devices at the assembly point, and offline
  devices upload after connectivity returns, which may be after the OSH
  Officer has closed the activation. A field event is accepted if its
  `client_timestamp` is no later than `closed_at` **plus 5 minutes**
  (`@late_event_tolerance_seconds`, a constant; to become a setting if OSH
  wants it tunable); later than that it is rejected with
  `{:error, :activation_closed}`. This is the one place `client_timestamp`
  is consulted; it is never used for ordering (I2).
- **Review actions** — kinds `override` and `contradiction_resolved`. These
  are not field observations but how OSH works the unaccounted list after
  the roll call: the officer reviews who is still unaccounted, confirms
  people safe by phone or otherwise, and overrides their status to excused
  with a mandatory note (docs/09, section 4; FR-ROLL-07). That work happens
  *after* close by design, so review actions are accepted at any time once
  the activation is `active`, `closed` or `reported`, with no time window.

An accepted late event of either class is stored and the person's status
re-derived exactly as if it had arrived on time. If the activation is
already `reported`, an additional audit row with action
`"accountability.late_event_after_report"` is written for either class —
**as of Stage B's completion, this is a write-only signal**: nothing in
`Salvorion.Reporting`, or anywhere else, currently reads this action back
to surface a "this report may be stale" prompt or offer a regenerate.
FR-REP-05's manual regenerate (`regenerate_report/2`, Prompt 11) exists and
works, but an OSH Officer has to think to trigger it themselves — the audit
row is only evidence, after the fact, that they should have. Wiring this
row to an actual regenerate-offered-automatically flow remains a real gap,
not yet closed.

## Accountability core (Prompt 6): contradiction resolution is an event, so I4 holds fully

A warden's "confirm" of a flagged contradiction (Document 11, section 1.5)
is recorded as an `AccountabilityEvent` of kind `contradiction_resolved`
(`status: "present"`, never a status change; note optional), ingested
through `Accountability.ingest_event/2` like every other event — same
`client_uuid` idempotency, same `"accountability.event_ingested"` audit
row. `resolve_contradiction/3` is a thin wrapper that checks an open
contradiction exists and then ingests that event; it never writes the
`person_statuses` row directly.

`derive_status/2` is therefore a pure function of the event log plus
`ExpectedPresence`, for every field: a `contradiction_resolved` event never
affects `status` or `source_event_id`; it resolves the contradiction if and
only if its `server_timestamp` is later than the contradicting roll-call
event's, with `contradiction_resolved_at` = the resolution event's
`server_timestamp`. A later `roll_call/absent` reopens the contradiction
exactly as before. Deleting and rebuilding a `PersonStatus` row reproduces
it field-for-field, including `contradiction_resolved_at`. (An earlier
draft set the column directly and documented it as the one field a rebuild
could not recover; that gap is closed.)

## Roll-call and dashboard reads (Prompt 7): a warden's scope is fixed at activation start

`Accounts.effective_warden_assignments/2` is always called with the
activation's `started_at` as `as_of`, never `DateTime.utc_now/0`. A warden's
zone/area scope for the whole activation is therefore fixed the instant the
drill starts; adding, ending, or changing a `WardenAssignment` mid-drill
never shifts who that warden already sees, for better or worse (a warden
reassigned mid-drill keeps seeing their original list for that drill). This
was a judgment call favouring predictability during an active incident over
reacting to admin changes mid-drill.

## Roll-call and dashboard reads (Prompt 7): "in scope" — roster location OR an event in this activation

A person is in scope for a warden (or a zone drill-down via
`list_roll_call_for_zone/2`) during an activation if EITHER:

1. their roster location touches it — any of `Scope.person_areas/1` (usual
   area, plus every area linked via `department_areas` to any of their
   departments) is in the warden's `area_ids`; OR
2. any of their events **in this activation** carries an `area_id` in the
   warden's `area_ids`, or an `assembly_point_id` belonging to a zone in the
   warden's `zone_ids`.

Rule 2 exists because rule 1 alone only ever surfaces people with roster
location data — staff, essentially. A student under `"signed_in_only"` (not
expected in advance, so no roster-derived scope membership) or a visitor
(no roster location at all) would otherwise never appear on *any* warden's
list, even standing in front of them having just signed in. Rule 2 puts
them on the list of the warden at the assembly point (or area) where they
actually turned up, which is what FR-ROLL-01/02 actually need: the warden
present at that location needs to see and be able to act on that person.

The same duality shapes the `{:person_status_updated, ...}` broadcast's
`zone_ids` (Task 5): they are the union of the person's roster-attributed
zones (`Scope.person_zone_ids/1`) and the zone(s) the triggering event's own
location resolves to (`Scope.event_zone_ids/1`) — the literal task wording
("zones the person is attributed to") would, read narrowly as roster-only,
silently drop every walk-in from the broadcast's intended fan-out; that
would defeat the stated purpose of letting a future Channel notify the
right wardens.

## Roll-call and dashboard reads (Prompt 7, follow-up): the after-commit broadcast guarantee is enforced, not assumed

The guarantee: `ingest_event/2` and `resolve_contradiction/3` each broadcast
`{:person_status_updated, ...}` strictly after their own transaction
commits, never from inside it, so a subscriber can never observe a message
for a write that then rolls back. That held by construction when each
function was the outermost `Repo.transaction/1` call — but nothing stopped
a caller from wrapping one in an *enclosing* transaction of its own. In
that shape the inner call's `{:ok, ...}` return does not mean "committed"
(Ecto runs an ordinary nested `Repo.transaction` as part of the same
underlying database transaction, no savepoint), yet the broadcast — a
plain message send, unrelated to Postgres commit timing — fires
immediately regardless of what the enclosing transaction does afterward.
Wrapped that way, the guarantee silently breaks.

The guard: both functions now call `Repo.in_transaction?()` first and
`raise ArgumentError` if it is true, naming the function and explaining
why (it manages its own transaction and broadcasts only after that
transaction commits, so it cannot safely run inside a caller's own
transaction) and what to do instead (ingest one event per call). This
turns a silent correctness gap into a loud, immediate failure at the call
site, the same day the mistake is made, rather than a subtle "the
dashboard didn't update for that one event" bug report much later.

The consequence: the future offline-upload endpoint, which receives a
batch of queued events from one device, must call `ingest_event/2` once
per event — never wrap the whole batch in one `Repo.transaction/1` and
call it in a loop. This is not a new constraint the guard imposes for its
own sake: per-event idempotency (`client_uuid`, I3) and partial-success
reporting (some events in a batch succeed, one fails validation, the
client needs to know which) both already want one event per transaction,
so the upload endpoint would have been built this way regardless. The
guard just makes it impossible to build it the other way by accident.

## Dashboard aggregates (Prompt 7): attribution and rate definitions

Recorded per the prompt's explicit decisions, since the documents left room:

- **Department attribution.** A person counts toward exactly one
  department's rates: their `primary_department_id`. Secondary memberships
  (`person_departments`) do not count toward rates, to avoid double
  counting the same person in two departments' participation figures. A
  person with no `primary_department_id` is attributed to a synthetic
  `"(no department)"` bucket (via SQL `COALESCE`, not a real row) so totals
  still reconcile.
- **Faculty attribution.** Staff via `primary_department.faculty_id`;
  students via `programme.faculty_id`. Nil (which is every real department's
  `faculty_id` in the current dev data — **corrected citation**: Document 01
  section 9 ("Assumptions") does not discuss faculties at all; the actual
  source is Document 15 (Stage B, Prompt 3)'s department extraction rule,
  "Create a Department record, with no faculty_id (faculties are not yet
  known ...)" — Document 15 itself cites Document 01 §9 for that claim, but
  that citation is also wrong there and was not in scope to fix in this
  docs-only pass, which only touched Documents 03/04/06/07/08/09/10/11 and
  this file) groups as `"(no faculty)"`.
  The query resolves this per-person with a `CASE WHEN type = 'staff'`
  expression, so it stays correct once faculties are actually assigned.
- **Rates.** `participation_rate = present / expected`, over expected
  people only. `accounted_rate = (present + absent + excused) / expected`.
  `present_unexpected` (present but not expected — a signed-in-only
  student, a visitor) is reported alongside every breakdown but never
  enters either rate's numerator or denominator. A group with `expected =
  0` gets rate `nil`, not `0`: the dashboard shows "n/a", not "0%", so a
  department nobody was expected in during a zones-scope drill does not
  read as total non-compliance. Choosing present/expected as the headline
  "participation" figure is a presentation decision, not a system
  constraint: an excused person lowers a department's participation rate
  even though they were accounted for. OSH or a Dean may prefer
  `accounted_rate` as the headline; both are computed, so this is a
  one-line change in the client, not in the API.
- **Zone attribution double-counts on purpose.** `counts_by_zone/1`
  attributes a `PersonStatus` to a zone via `Scope.person_area_pairs_query/0`
  resolved to each area's zone. A person whose areas span two zones (a
  department with areas in two different zones, or a person with a usual
  area in one zone and a department area in another) is counted in **both**
  zones' `expected`/`present`/etc. This mirrors `list_roll_call/2`'s own
  scope resolution, which has the same property for the same reason: each
  zone's warden needs to see everyone whose safety they might be
  responsible for, even if that overlaps another warden's list. The
  headline `activation_summary/1` figures are not affected — they count
  every `PersonStatus` row once, never per zone.

## Visitors (Prompt 8): the pass code doubles as `id_number`

A registered visitor's `Person.id_number` is set to a generated pass code,
`"VIS-"` followed by 8 characters from Crockford's base32 alphabet
(`0123456789ABCDEFGHJKMNPQRSTVWXYZ` — deliberately excludes I, L, O, U,
which are visually confusable with 1, 1, 0 and V), drawn from
`:crypto.strong_rand_bytes/1` (256 is exactly divisible by 32, so
`rem(byte, 32)` introduces no modulo bias). This was a decision, not a
requirement fixed by the documents: it means a visitor's temporary QR pass
(FR-VIS-02) is resolved by exactly the same code path as a staff or student
ID card scan (`Roster.get_person_by_id_number/1`, FR-SIGN-01) — there is no
separate "visitor scan" branch anywhere in ingest, which is also why
`Person.id_number`'s partial unique index (`WHERE id_number IS NOT NULL`)
now covers visitors too, not just staff/students (docs/06).

Collision handling: the pass code space is `32^8 ≈ 1.1 * 10^12` combinations,
so a collision against the existing roster is astronomically unlikely, but
`register_visitor/2` still retries generation (up to 5 attempts) on the
unique-constraint violation rather than assuming it away, the same
discipline `Activations`' zone-overlap guard and `Accountability`'s
per-person lock apply to their own low-probability races.

## Visitors (Prompt 8): an expired pass scanned during an activation is still accepted

`ingest_event/2` never checks `visitor_expires_at` before resolving an
`id_number` to a person — it only ever asks "does this pass code belong to
someone" (FR-SIGN-01's ordinary lookup), never "is this pass still valid."
A visitor whose pass has technically expired but who is physically present
and scans in during a real activation is still recorded as present: the
fact that matters during an emergency is where people are, not whether
their paperwork is current, and FR-VIS-03 requires visitors be counted like
anyone else. `list_visitors/1`'s `:active_on` filter and a possible future
client-side warning on an expired pass are presentation concerns for
reception/registration screens, not an accountability gate.

## HTTP layer (Prompt 9): pagination is deferred to `GET /api/people`, not forgotten elsewhere

Task 1 asked every success response to be `{data: ...}` or, for a paginated
list, `{data: [...], meta: {...}}`. Only `GET /api/people` actually paginates
(`limit`/`offset`, default `limit: 50`, plus `meta.total` via
`Roster.count_people/1`): with 1,373 people in the dev roster already and a
roster that only grows, this is the one list an API client could plausibly
need to page through. Every other list route in this prompt
(`/api/faculties`, `/api/departments`, `/api/programmes`,
`/api/assembly-points`, `/api/zones`, `/api/areas`, `/api/users`,
`/api/warden-assignments`, `/api/roster-imports`, `/api/activations`, every
dashboard read) returns its full result unpaginated: none of these tables
are expected to reach a size where that matters in Release 1 (a few dozen
zones/areas/departments, a few users, a handful of activations per term).
`list_audit_logs/1` (`Salvorion.Audit`) already takes a `:limit` — it has no
route yet (audit log viewing is a later prompt) but will paginate the same
way `list_people/1` does when that route is built. This is a scoping
decision to revisit if any of these other lists turns out to grow
unexpectedly large, not an oversight.

## HTTP layer (Prompt 9): the RBAC entries that don't come straight from Document 10 section 1

Most of `SalvorionWeb.RBAC`'s new rows cite a section 1 row directly, cited
in a comment next to the row itself. Five don't, or extend one beyond its
literal reading, each recorded here as well since a reviewer scanning
`docs/10-security-design.md` side-by-side with the matrix would otherwise
wonder where they came from:

- **`GET /api/faculties`/`/departments`/`/programmes`, `GET
  /api/assembly-points`/`/zones`/`/areas`.** Not a section 1 row at all —
  section 1 only lists *write* permissions for these resources ("Manage
  assembly points, zones, areas", "Manage departments, faculties,
  programmes"); reading them is covered instead by section 2's data
  classification table ("Directory information ... visible to any
  authenticated user role in the course of their duties"). All reads here
  are `@all_roles`, and always have been, since this prompt.
- **`GET /api/people`, `GET /api/people/:id`, `GET /api/people/lookup`.**
  Same section-2 reasoning applies, but this prompt's own rows were
  narrower than that reasoning actually supports: `[@admin, @osh, @warden]`,
  excluding `report_viewer` with no documented reason. Document 25/26's
  Task 1 ("people-lookup routes widened to all four roles," below) closed
  that gap after the fact — these three routes are `@all_roles` now, but
  were not from this prompt onward until that later fix.
- **`POST /api/faculties`/`/departments`/`/programmes`: admin only, not
  osh_officer.** The prompt that specified this route anticipated needing
  to *guess* this permission (asking me to fall back to Locations' shape
  and flag it for confirmation if organisation management wasn't listed
  separately). It didn't need guessing: Document 10 section 1 has its own
  row, "Manage departments, faculties, programmes: Yes / No / No / No" —
  admin only, explicitly distinct from "Manage assembly points, zones,
  areas" (Yes/Yes/No/No), which does include OSH Officer. I implemented the
  literal row rather than the fallback the prompt offered.
- **`POST /api/devices/:id/revoke`: every role passes the RBAC gate.**
  Section 1 has no row for this at all (device revocation isn't in the
  matrix); the permission comes from section 4 ("a lost or decommissioned
  device's access can be revoked") plus the later prompt's own instruction
  ("admin, or the device's own user"). Ownership isn't a role, so the table
  can't express it — every authenticated role is let through, and
  `DeviceController.revoke/2` does the actual admin-or-owner check,
  returning `{:error, :forbidden}` (403) otherwise.
- **`GET /api/activations/:id`: extended to `warden`, beyond "View
  activation history"'s literal No.** Section 1's "View activation
  history: Yes/Yes/No/Yes" is about the *list* of past activations
  (`GET /api/activations`, which stays admin/osh_officer/report_viewer
  only). A warden fetching the *one* activation they are currently working
  — to know its type, status, and timing while using the roll-call screen
  — is a different, narrower thing than browsing history, and the app
  cannot function for a warden without it (the roll-call screen needs to
  show the activation's own status and type). This is a judgment call, not
  a literal section 1 entry; flagging it for confirmation rather than
  presenting it as if the matrix settled it.
- **`POST /api/activations/:id/events`: allows `admin`/`osh_officer` to
  post a `roll_call` kind, though section 1's "Conduct roll call" row lists
  only Safety Warden as Yes.** This route is one shared ingest endpoint for
  every event kind (`scanned`, `manual`, `roll_call`, `visitor_registered`,
  `override`, `contradiction_resolved`), not a roll-call-specific one, so it
  takes the union of roles that need *any* kind through it — including
  "Perform sign-in" and "Register a visitor" (both Yes/Yes/Yes/No). Nothing
  in the app currently stops an admin from posting a `roll_call` kind here,
  which the matrix's literal per-row reading would not grant them. Noted as
  a gap between "one endpoint per kind" (unambiguous) and "one endpoint for
  every kind" (what was actually asked for), not something I resolved by
  splitting the route.

## PowerSync sync config (Prompt 10): Sync Streams, not Sync Rules

Confirmed against documentation before writing `docker/powersync/sync-config.yaml`, per the prompt's own Task 0.

- **journeyapps/powersync-service:1.26.0 uses Sync Streams (`config: edition: 3`, top-level `streams:` key), not legacy bucket-based Sync Rules (`bucket_definitions:`).** Sync Streams reached General Availability on 14 May 2026 ([PowerSync — Sync Streams Are Now Generally Available](https://releases.powersync.com/announcements/sync-streams-are-now-generally-available)); edition 3 has existed since at least service version 1.20.0 (a GitLab Advisory Database entry for a 1.20.0-era edition-3 bug — [GHSA-q6wc-xx4m-92fj](https://advisories.gitlab.com/npm/@powersync/service-sync-rules/GHSA-q6wc-xx4m-92fj/) — fixed by 1.23.3), so 1.26.0 both postdates GA and has had edition-3 support for many releases. [Self-Hosted Instance Configuration](https://docs.powersync.com/configuration/powersync-service/self-hosted-instances) confirms `sync_config.path` in `powersync.yaml` (already how this repo's config is wired — see `docker/powersync/powersync.yaml`) points at a file using either format; edition 3's schema is `config: {edition: 3}` plus `streams: {...}`, each stream a `query` (or `queries:` list) plus optional `with:` (CTEs) and `auto_subscribe`. Legacy Sync Rules remains supported but is explicitly called out as legacy, with deprecation "eventually" (no date fixed) once an LTS plan is published.
- **Documentation was sufficient here** (no need for empirical settling on the format question itself), but the *query dialect's* exact restrictions were only settled empirically against this running container — see the next three entries. `docker/powersync/sync-config.yaml`'s own header comment carries the full citation list.
- JWT claim access, confirmed against [Sync Streams (Early Alpha)](https://docs.powersync.com/usage/sync-streams) and the [Sync Streams examples](https://docs.powersync.com/sync/streams/examples) page: `auth.user_id()` reads the verified JWT's `sub` claim; `auth.parameter('<claim>')` reads any other claim (here, `role`, set by `Salvorion.Accounts.Guardian.build_claims/3`, Prompt 2). There is no separate "PowerSync-specific" claims mechanism to configure — it reads whatever `client_auth.jwks_uri` verifies.

## PowerSync sync config (Prompt 10): `sync_safe_users` cannot be the sync source — a Postgres, not PowerSync, limitation

Task 3 asked for a Postgres view (`sync_safe_users`, columns `id, email, role, active, inserted_at, updated_at` — never `password_hash`) as a second, independent barrier, with the sync stream reading from the view rather than `users` directly. Empirically confirmed this does not work, and *cannot* work regardless of PowerSync version:

- `docker/postgres/init/01-powersync.sh` runs `CREATE PUBLICATION powersync FOR ALL TABLES`. In PostgreSQL, `FOR ALL TABLES` (and `CREATE PUBLICATION` generally) can only ever include base tables — a view has no WAL entries of its own, so it cannot be a logical-replication source. This is confirmed directly against the running database: `SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'powersync'` lists `users` but never `sync_safe_users`.
- A sync stream (`sync_safe_users: { query: SELECT * FROM sync_safe_users WHERE id = auth.user_id() }`) pointed at the view loaded with **no error** — the config parser accepted it — but it never appeared in the container's own `"Replicating \"public\".\"<table>\" ..."` startup log the way every real table does, and produced zero rows for every client. This is the dangerous failure mode: not a loud rejection, a silent one.
- **Fix:** the stream queries `users` directly, repeating the view's own explicit column list (`SELECT id, email, role, active, inserted_at, updated_at FROM users WHERE id = auth.user_id()`) rather than `SELECT *`. `password_hash` is named nowhere in `docker/powersync/sync-config.yaml`. The `sync_safe_users` view stays in the schema (migration `20260913000001_create_sync_safe_users_view.exs`) purely as the second, reviewable barrier Task 3 was actually after: it is no longer the literal sync source, but it still means a future engineer who wants `password_hash` to reach a client has to touch two places, one of which (the view) reads as an obviously deliberate, reviewable change — the defense-in-depth intent survives even though the literal mechanism (view-as-sync-source) does not.

## PowerSync sync config (Prompt 10): the warden's "currently effective" filter cannot be evaluated by the sync engine

Task 5 asked for a warden's accountability scope to be filtered by `warden_assignments.starts_at`/`ends_at` against the current wall-clock time. PowerSync's stream query engine categorically disallows `now()`/`CURRENT_DATE`/`CURRENT_TIMESTAMP` (or any non-deterministic function) in any query that determines row or bucket membership — documented directly, with three named workarounds (a boolean column refreshed by a scheduled job, date-string bucketing, or coarser granularity buckets), on [Sync Data by Time with Sync Streams](https://docs.powersync.com/sync/advanced/sync-data-by-time). None of the three fit this prompt's own stated boundary (no Elixir code outside Task 3; no new Postgres extension/cron infrastructure was in scope either).

**Decision:** `docker/powersync/sync-config.yaml`'s `warden_assignments_own`, and every `*_warden_*` stream's `warden_areas`/`warden_zones` CTEs, filter only by `user_id = auth.user_id()` — no date condition at all. A warden's sync-layer scope is therefore every `warden_assignments` row ever made for them (past, current and future), not the currently-effective subset. This is a **different and additional** discrepancy from the one the prompt already anticipated for the API layer (`Accounts.effective_warden_assignments/2` pins to `activation.started_at`, never `DateTime.utc_now/0` — see "Roll-call and dashboard reads (Prompt 7): a warden's scope is fixed at activation start" above): that entry is about *which instant* "effective" is measured against; this one is that the sync layer cannot measure against *any* instant, because PowerSync structurally cannot evaluate wall-clock time. The API's own roll-call and dashboard reads are unaffected — they still call `effective_warden_assignments/2` and get the correct, date-scoped answer. Only the client's locally-replicated row set is wider than "currently effective" would be. If OSH ever needs this tightened, the only compliant paths are the three PowerSync-documented workarounds above, all of which require infrastructure (a scheduled job of some kind) beyond this prompt's scope.

## PowerSync sync config (Prompt 10): `person_statuses`' event-location rule uses `source_event_id`, not every event in the activation

`Accountability.Scope.in_scope_person_ids_query/2`'s rule (ii) checks *any* `accountability_events` row for a person in the activation, not just the one that set their current status. Translating that literally into a sync stream would require a correlated subquery (`WHERE EXISTS (SELECT 1 FROM accountability_events WHERE activation_id = person_statuses.activation_id AND person_id = person_statuses.person_id AND ...)`), which is a materially different, more powerful construct than the uncorrelated `col IN (SELECT ... FROM cte)` pattern the documented examples all use, and was not empirically verified to be supported.

**Decision:** `person_statuses_warden_event_area`/`person_statuses_warden_event_zone` join to `accountability_events` via `person_statuses.source_event_id` only — an ordinary, uncorrelated foreign-key join. This is narrower than Scope's Elixir implementation: a person whose *current* status came from a roster-scoped event (so rule (a) already covers them) but who *also* has an unrelated, differently-located event in the same activation would be in scope either way, so this narrowing only matters for a person whose current status event's location is outside the warden's scope while a different, past event's location was inside it — an edge case Scope's own design already treats as "the warden should see it," but which this sync layer will miss. Not fixed here; recorded for whoever next revisits the sync config once/if PowerSync ships correlated-subquery or `EXISTS` support in Sync Streams.

## PowerSync sync config (Prompt 10): `expected_presences` has no event-location rule, by construction, not by omission

Task 5's rule (b) ("the event's own area_id/assembly_point_id") has no counterpart for `expected_presences`, and none was added: `expected_presences` rows are only ever written by `Accountability.initialise_for_activation/1` from roster location (staff, by `usual_area`/`department_areas`) or, under the `all_enrolled` student rule, unconditionally — never from a walk-in event. A person with no roster location in scope (a `signed_in_only` student, a visitor) simply never gets an `expected_presences` row at all, so there is no row for rule (b) to ever apply to. The three `expected_presences_warden_*` streams therefore only implement rule (a).

## PowerSync sync config (Prompt 10): query-dialect quirks worth knowing before writing the next stream

Found empirically against the running 1.26.0 container (config reload logs its own errors as structured JSON with SQL snippets, which made this fast to diagnose):

- **`auth.parameter('role') IN ('a', 'b')` is a fatal config error** — `"This expression is not supported by PowerSync"` / `"This table-valued function depends on request data and can't be partitioned."` Only `=` is supported against `auth.parameter(...)`/`auth.user_id()`; write `(auth.parameter('role') = 'a' OR auth.parameter('role') = 'b')` instead. `IN` against an ordinary table column (not an auth parameter) is fine and used throughout this config.
- **Aliasing the primary (`FROM`) table renames the client-side synced table.** `SELECT ae.* FROM accountability_events ae INNER JOIN ...` syncs its rows under a table called `ae`, not `accountability_events` — logged as a (non-fatal) warning, not an error, so it is easy to ship silently. Every query in `docker/powersync/sync-config.yaml` that joins therefore leaves the primary table unaliased (`FROM accountability_events`, referencing `accountability_events.person_id` etc. by full name) and only aliases *joined* tables, which does not trigger the warning.
- **A stream's multiple `queries:` entries must "filter on the same parameters in the same way"** (documented on the [Sync Streams queries](https://docs.powersync.com/sync/streams/queries) page) to be merged into one stream. Rather than test how strict this is, this config gives every independent condition (the role-based full-access branch, each of the roster-location branches, each of the event-location branches) its own top-level **stream**; PowerSync unions rows from any number of streams that target the same table into the same client-side table, so nothing is lost by not sharing one stream, and the config stays one rule per stream, which is easier to review against Document 10 section 1 line-by-line.

## PowerSync sync config (Prompt 10): device revocation has a JWT-expiry-bounded blind spot

PowerSync authenticates a connection by verifying the presented JWT's signature and expiry only (`client_auth.jwks_uri`, `docker/powersync/powersync.yaml`) — it has no knowledge of `devices.revoked_at`. `POST /api/devices/:id/revoke` (Prompt 9) stops the device working against the Phoenix API immediately (`SalvorionWeb.Plugs.Authorize` checks `Accounts.device_revoked?/1` on every request), but a still-unexpired access token issued before revocation continues to authenticate to PowerSync — and therefore continues to sync — until that token naturally expires. The bound is precise: **worst case 15 minutes**, matching the access token TTL (Document 10, section 4). No code change in this prompt addresses this; it is an inherent property of stateless JWT authentication with a service (PowerSync) that only verifies signature and expiry, not a Salvorion-specific gap.

Verified empirically (Prompt 10 verification item 7), against the real running stack: with W5's device revoked via `POST /api/devices/:id/revoke` (confirmed the Phoenix API itself now rejects that token immediately: `GET /api/auth/me` → 401 `{"errors":{"detail":"unauthorized"}}`), reconnecting the test client with the *same, still-unexpired* access token succeeded and replicated the full expected row set unchanged — PowerSync has no way to know the device was revoked. A second access token, minted with an artificially short 30-second TTL to avoid a real 15-minute wait, replicated successfully immediately after issue, then — reconnecting ~30+ seconds later with that same now-expired token — PowerSync rejected the connection outright: `401 Unauthorized`, `{"error":{"code":"PSYNC_S2103","status":401,"description":"JWT has expired","name":"AuthorizationError"}}`, `SyncStatus.connected = false`. So PowerSync does correctly enforce expiry; it simply has no channel to learn about revocation before that. Worth OSH knowing, and a candidate for a future short-TTL-plus-revocation-check webhook if PowerSync's self-hosted/Open Edition ever exposes one — none was found in the documentation consulted for this prompt.

## Reporting (Prompt 11): Gotenberg's exact HTML-to-PDF contract, confirmed against real documentation

Confirmed against [Gotenberg's own docs](https://gotenberg.dev/docs/convert-with-chromium/convert-html-to-pdf) before writing `render_report_pdf/1`, per the prompt's own instruction not to guess: `POST /forms/chromium/convert/html`, `multipart/form-data`, the HTML part under form field `files`, and Gotenberg identifies the entry document by **filename**, not by field name or content-type — it must be named exactly `index.html`. `Reporting.render_report_pdf/1` builds this with Req's `:form_multipart` option (`{html, filename: "index.html", content_type: "text/html"}`) rather than guessing at a different field/filename convention. Tested against the actually-running `salvorion-gotenberg` container (Prompt 1), not a mock — see the verification report.

## Reporting (Prompt 11): the report template is compiled with `Phoenix.HTML.Engine`, not plain `EEx.eval_file/2`

Task 3 asked for "whichever Phoenix templating already supports without adding a new dependency." `phoenix_html` and `phoenix_template` are already resolved transitive dependencies (via `phoenix_ecto`/`phoenix_live_view`) even though this app is `--no-html`, so nothing new was added to `mix.exs`. `Reporting.render_report_pdf/1` compiles `priv/report_templates/activation_report.html.eex` with `EEx.compile_file(path, engine: Phoenix.HTML.Engine)` and evaluates it with `Code.eval_quoted(compiled, assigns: data)`, then `Phoenix.HTML.safe_to_string/1`. Empirically confirmed (`mix run` against a throwaway snippet) that `@foo`-style assign access works inside a template compiled this way with no enclosing view module, and that interpolated values are HTML-escaped by default — worth confirming rather than assuming, since `@foo` sugar is normally only seen inside a compiled Phoenix view. `format_rate/1` (turns a `nil`/float rate into `"n/a"`/`"50.0%"`) is a **public** function on `Salvorion.Reporting` for exactly this reason: the template is not compiled inside any module, so it can only call a function by a fully-qualified name, never a local or private one.

## Reporting (Prompt 11): `ReportDelivery` rows are created up front at generation time, not lazily inside `DeliverReportWorker`

`GenerateReportWorker.enqueue_deliveries/1` calls `Reporting.get_or_create_delivery/2` for every currently-active recipient itself, immediately after marking the run `generated` — before enqueueing that recipient's `DeliverReportWorker` job, not inside it. This was not the first design tried: creating the delivery row lazily, inside `DeliverReportWorker.perform/1` (which is what Task 5's wording, read literally, suggests — "creates or updates the corresponding ReportDelivery row"), makes `Reporting.finish_run_if_complete/1`'s "is any delivery still pending?" check meaningless until every recipient's job has *started* — a delivery job that has not yet run has no row at all, which is indistinguishable from "already handled." A test written to prove "the activation isn't reported until both recipients' deliveries settle" caught this directly: performing only the first of two recipients' jobs against a lazy-creation design still finished the run, because the second recipient's row simply did not exist yet to be "pending." `DeliverReportWorker` still calls `get_or_create_delivery/2` too (Task 5's literal wording), but by the time it runs, the row from generation always already exists — the "or updates" half of that function's job now only ever fires on a genuine retried delivery attempt, which is exactly what it was written for anyway.

## Reporting (Prompt 11): a concurrent double-`mark_activation_reported/1` is an accepted, low-probability race

`Reporting.finish_run_if_complete/1` (called once per `DeliverReportWorker` job as it settles) can, if two of a run's deliveries finish at nearly the same moment under the `:reports` queue's concurrency of 2, both observe "zero deliveries still pending" and both call `Activations.mark_activation_reported/1`. The second call is a harmless no-op, but **not** by producing a logged, discarded changeset error as an earlier draft of this entry claimed: `Activation.mark_reported_changeset/1` requires `status == "closed"` on the struct it's given, which is no longer true by the time the second call reloads the activation, so the changeset already carries a validation error before `mark_activation_reported/1`'s `Multi.new() |> Multi.update(...) |> audit(...) |> run_audited(...)` chain ever reaches `Repo.update/1` — the whole `Multi` **fails outright and rolls back**, so no audit row is written for the second call. `finish_run_if_complete/1`'s own `case` on the result simply discards the `{:error, changeset}` — nothing is logged anywhere, at any level; the only trace this happened at all is the absence of a second `"activation.reported"` audit row where a careless reviewer might otherwise expect one. Not fixed with a lock, for the same reason the synthetic-roster-ID race (Prompt 4) and the visitor-pass-code collision handling (Prompt 8) weren't: a low-probability, silently-discarded duplicate call on a non-safety-critical path, not a correctness or data-loss risk.

## Reporting (Prompt 11): generated report storage is a Release 1 limitation, recorded for the deployment prompt

`priv/generated_reports/{activation_id}-{report_run_id}.pdf` (Task 4) is local filesystem storage under the application's own `priv/` directory — fine for a single-instance deployment (Document 08 section 6's initial deployment diagram: one application VM), but it will not survive a redeploy, does not work across multiple application instances, and has no backup story of its own (unlike the managed Postgres database). Before any deployment beyond the current single-VM plan, this needs to become real object storage (S3 or equivalent) with `ReportRun.pdf_path` changed from a local path to an object key/URL. Not addressed in this prompt — recorded here for whoever does Document 08 section 6's later "Stage D: deployment" work (`Salvorion.Reporting.render_report_pdf/1`'s caller, `GenerateReportWorker`, is the only place a storage-layer change would need to happen; `Reporting.report_pdf_path/2`'s signature could stay the same).

## Reporting (Prompt 11): Amazon SES is configured but unverified

Task 6 asked for `Swoosh.Adapters.AmazonSES` in production only, guarded by `config_env() == :prod` in `config/runtime.exs` exactly like the Guardian key path — done, and `ex_aws`/`ex_aws_ses` were added to `mix.exs` as real dependencies for it. Per the prompt's own instruction, no attempt was made to actually send email anywhere in this prompt's verification: there are no AWS credentials in this environment, `config/runtime.exs`'s SES branch only ever runs when `config_env() == :prod` (never in dev or test, confirmed — `mix compile`/`mix test` do not evaluate that branch and need no `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` to succeed), and the two new dependencies compile without requiring any credential to be present. **The interface is complete and swappable via config alone; SES itself is unverified until real AWS credentials exist.** Whoever first deploys to production should send one real report email deliberately, with SES in sandbox mode against a verified test address, before relying on FR-REP-03's "within 15 minutes" for a real activation.

## Reporting (Prompt 11): a pre-existing `async: true` / advisory-lock flake, one file fixed, the pattern flagged rather than swept

Running the full suite after adding this prompt's tests, `activation_controller_test.exs` (pre-existing, unrelated to Reporting) intermittently failed with `Postgrex.Error ... query_canceled` inside `Activations.acquire_start_lock/1`. Cause: `start_activation/2` serialises every caller on one fixed Postgres advisory-lock key (`Activations`' own moduledoc explains why — campus-wide activations have no `activation_zones` rows for a partial unique index to key off), and this test file runs `async: true` despite calling `start_activation/2` in nearly every test — `ActivationsTest` itself is deliberately `async: false` for exactly this reason, but that reasoning was never applied to the controller test. This prompt's own new tests (several real-Gotenberg-HTTP-bound `async: false` tests, run serially) lengthened the full suite's wall-clock time enough to make the pre-existing race actually surface, which is why it looked at first like a Prompt 11 regression rather than a latent gap `activation_controller_test.exs` always had.

Fixed the one file that actually failed (now `async: false`, matching `ActivationsTest`'s own precedent), and confirmed by rerunning the full suite. **Not swept further, at the time of this prompt**: `event_controller_test.exs`, `visitor_controller_test.exs`, `accountability_reads_controllers_test.exs` and `roster_visitors_test.exs` all also called `start_activation/2` under `async: true` and shared the same latent risk, but did not fail in this run and belonged to earlier prompts outside Reporting's scope — recorded here so whoever next saw an unexplained `query_canceled` failure in one of them would know the cause immediately rather than re-diagnosing it, rather than "fixed" speculatively across files this prompt had no other reason to touch. **Superseded:** by the time of the Document 25 consistency audit, all four of these files had independently become `async: false` (each acquired for its own reason — real HTTP/PII test additions in later prompts, not a deliberate sweep of this entry's list), so the latent risk this paragraph flagged no longer applies to any of them; confirmed directly against each file's `use ...Case, async: false` declaration.

## Reporting (Prompt 11): closing an activation must itself enqueue `GenerateReportWorker` — not stated by name in Task 5, required by FR-REP-01 and Document 08 section 4

Task 5 specifies what `GenerateReportWorker` does once it has an `activation_id`, and Task 7 specifies the *manual* regenerate trigger (`regenerate_report/2`), but nothing in the prompt's task list says who enqueues the worker the first time, automatically, when an activation closes. FR-REP-01 ("The system shall automatically generate a report when an activation is closed") and Document 08 section 4's own sequence diagram are explicit that this happens as part of the close request itself ("`API->>Oban: Enqueue GenerateReportJob(activation_id)`", drawn as a step of the `PATCH /activations/:id` flow, immediately after `Activations` reports the transition succeeded) — so this was read as a real requirement to implement, not an optional nicety, even though no task named it directly.

`SalvorionWeb.ActivationController.close/2` now enqueues `GenerateReportWorker` immediately after `Activations.close_activation/2` succeeds. Deliberately **not** placed inside `Salvorion.Activations.close_activation/2` itself, matching the sequence diagram's own layering (the enqueue is drawn as the API's action, not the Activations context's) and keeping `Salvorion.Activations` free of any dependency on `Salvorion.Reporting` — the dependency arrow already runs the other way (`Reporting` depends on `Activations` for `get_activation!/1` and `mark_activation_reported/1`), and a context reaching back into a context that depends on it would be a real layering smell. Caught by walking through this prompt's own verification script end-to-end against a real activation, rather than by anything the automated test suite would have caught on its own (every Reporting/worker test in this prompt calls `Activations.close_activation/2` directly, bypassing the controller, so none of them would have noticed this endpoint never enqueued anything) — a reminder that a context-level test suite proving each piece works in isolation does not prove the pieces are actually wired together end to end.

## Realtime (Prompt 12): the revocation/expiry self-check interval is 5 minutes — a starting number, not a documented requirement

`ActivationChannel` schedules a recurring self-check via `Process.send_after/3` (`@revocation_check_interval`, `:timer.minutes(5)`) that re-queries `devices.revoked_at` for the socket's `device_id` (if any) and recomputes expiry against the `exp` claim already decoded at connect time (Task 1) — never a full `Guardian.decode_and_verify/2` re-run, since the signature was checked once already and cannot change out from under an open connection. On either condition, the channel pushes `session_revoked` and terminates itself (`{:stop, :normal, socket}`); this closes only that one channel/socket, not any other channel the same user holds open on a different device — each device's connection is its own `Phoenix.Socket` process (Task 1's `id/1`, `"user_socket:#{user_id}"`, exists so all of a user's sockets *could* be found and disconnected together via `Endpoint.broadcast("user_socket:#{user_id}", ...)` in some future prompt that wants to force-log-out every device at once, but nothing here does that; Task 3 only ever needs to close the one device's own channel).

Five minutes is a trade-off, not a spec requirement — no FR/NFR in the SRS names a number here. Shorter bounds the exposure window tighter (a revoked device or expired token is at most that long finding out it's cut off) at the cost of one extra `devices` query per open channel every interval; five minutes costs nothing measurable at this system's scale (an assembly point activation lasting a warden's shift, not a consumer app with a large number of concurrent sockets) while still bounding "how late can a cut-off device learn it's cut off" to a fraction of the access token's own 15-minute life (Document 10, section 4). If OSH later wants a tighter bound, this is the one constant to change.

## Realtime (Prompt 12): confirmed against PowerSync's own documentation — no server-push disconnect for an already-open connection exists

Task 3 asked this channel to be more responsive than "the PowerSync gap documented in Prompt 10" without assuming PowerSync's own limitation symmetrically — to check the claim against real documentation before stating it, not guess. Checked directly against `docs.powersync.com` before writing this: the authentication page ([Custom Authentication](https://docs.powersync.com/configuration/auth/custom)), the [PowerSync Protocol](https://docs.powersync.com/architecture/powersync-protocol) page, and the [Client Architecture](https://docs.powersync.com/architecture/client-architecture) page. **Confirmed.** PowerSync's own docs state plainly: "Since there is no way to revoke a JWT once issued without rotating the key, we recommend using short expiration periods (e.g. 5 minutes)" — i.e. the *only* way PowerSync can invalidate a token before its own `exp` is rotating the service's entire signing key, which invalidates every token for every user and device at once, not the one device Salvorion would want to cut off. Nothing on the protocol or client-architecture pages describes any push frame, close code, or other server-to-client message that targets a single open connection for early termination; the protocol page's only remark on interruption — "The stream can be interrupted at any time, at which point the client will initiate a new session, resuming from the last point" — describes client-initiated reconnection after a network interruption, not a server-initiated one.

This lines up with, and gives a documented reason for, Prompt 10's own empirical finding ("PowerSync sync config (Prompt 10): device revocation has a JWT-expiry-bounded blind spot", above): a revoked device's still-unexpired token went on syncing via PowerSync until it naturally expired, because PowerSync had no channel to learn about the revocation early. `ActivationChannel`'s 5-minute self-check gives Salvorion's own real-time layer a capability PowerSync itself does not have and, per its own documentation, cannot have without a key rotation blunt enough to also log out every other user and device.

## Consistency audit follow-up (Document 25/26): event attribution could be forged

`SalvorionWeb.EventController.create/2` built the attrs it passed to `Accountability.ingest_event/2` with `Map.put_new("recorded_by_id", conn.assigns.current_user_id, params)` — if the request body already contained a `recorded_by_id`, the client's value won, since `Map.put_new/3` only fills in a *missing* key. `Accountability.check_override_permitted/1` (the check gating the `override` kind to `osh_officer`/`admin`) authorises by looking up **that id's** role, not the authenticated caller's. The consequence: any authenticated warden could POST `kind: "override"` with `recorded_by_id` set to an OSH officer's id (visible to any warden via `GET /api/activations/:id`, whose `started_by_id` is always an officer) and the override would be accepted as if the officer had performed it — FR-ROLL-07's "OSH Officer or System Administrator" gate had no teeth. The same forgery attributed *any* event kind to anyone, not just overrides: a warden could make a sign-in, a roll-call mark, or a visitor registration read as recorded by a different user entirely, including the report's manual sign-in log (`recorded_by_email`). A similarly unvalidated `device_id` in the body could name any device on file, not just one belonging to the caller.

The pre-existing test suite passed straight through this: `event_controller_test.exs`'s only override test ("override by a warden is 403") never sent `recorded_by_id` in the body at all, so it exercised the honest path (`Map.put_new` filling in the caller's own id) and never noticed the dishonest one was accepted too.

**Fix**, `lib/salvorion_web/controllers/event_controller.ex`: `Map.put/3`, not `Map.put_new/3` — `recorded_by_id` is now unconditionally overwritten with `conn.assigns.current_user_id`, so nothing in the request body can ever change who an event is attributed to. A `device_id` in the body is now validated against `Accounts.get_device/1` — it must be a device row whose `user_id` matches the authenticated caller, or the whole request is rejected (`{:error, :forbidden}`, 403) rather than the device_id being silently accepted or silently dropped.

Three new tests in `event_controller_test.exs` cover this: a warden posting `kind: "override"` with a forged `recorded_by_id` naming an osh_officer now gets 403 (the check evaluates the warden's real role, not the forged id); posting any event with a forged `recorded_by_id` records the authenticated caller as `AccountabilityEvent.recorded_by_id` and as the audit row's `actor_user_id`, never the forged value; and a `device_id` belonging to a different user is rejected outright.

## Consistency audit follow-up (Document 25): activation starter and start time could be forged

`Salvorion.Activations`' shared `normalize_attrs/2` helper used `Map.put_new("started_by_id", actor_id(opts))` and `Map.put_new("started_at", DateTime.utc_now())`, and `SalvorionWeb.ActivationController.create/2` (`POST /api/activations`) passes raw request params straight into `start_activation/2`. Either field, if present in the request body, silently won over the honest default. `started_by_id` forged who FR-ACT-06 records as having started the activation; `started_at` forged **when** — and `started_at` is not cosmetic: it is the exact instant `Scope.warden_scope/2` pins every warden's zone/area scope to for the whole activation (Prompt 7, "a warden's scope is fixed at activation start"), and every dashboard/report figure keyed off the activation is computed relative to it. A backdated `started_at` could shift which `WardenAssignment` rows count as effective, or simply misrepresent how long an activation had been running in the closing report.

**Fix**, `lib/salvorion/activations.ex`: `normalize_attrs/2` now unconditionally `Map.put`s `started_by_id` from `opts[:actor]` and no longer touches `started_at` at all — each caller now applies its own `started_at` policy explicitly, because the two callers need different rules, not the same fix:

- **`start_activation/2`'s map-attrs clause** — the path `POST /api/activations` actually calls with untrusted params — now unconditionally `Map.put`s `started_at` to `DateTime.utc_now()` after `normalize_attrs/2`, exactly like `started_by_id`. This is the reachable, consequential path, so nothing in the request body can backdate it or attribute it to someone else.
- **`schedule_activation/2`** still accepts a caller-supplied `started_at` (`Map.put_new`, defaulting to now if omitted) — deliberately **not** changed to force `DateTime.utc_now()`. A future planned time is the entire documented purpose of scheduling ahead (Document 03 §4, the `scheduled` state in Document 08 §5); forcing it to "now" would silently remove the ability to schedule anything in advance. This function also has no HTTP route yet (confirmed against `router.ex` — only `create`, `start`, `close`, `index`, `show` exist for activations), so there is no untrusted-input path into it to close in the first place. When `schedule_activation/2` does get a route, whoever adds it should re-examine whether `started_at` needs a plausibility bound (e.g. "not more than N days in the future") — that is a product question, not a forgery-closing one, and out of scope here.

One new test in `activations_test.exs`: an OSH officer starts an activation with both `started_by_id` (a different user) and `started_at` (a week in the past) supplied in attrs; asserts the real caller and a `started_at` within the test's own before/after window are what actually land, never the forged values.

## Consistency audit follow-up (Document 25): the visitor-registration audit row kept personal data the purge job never reached

`Roster.purge_expired_visitors/1` correctly anonymises the `Person` row once a visitor's retention period elapses (`first_name`, `last_name`, `email`, `phone`, `visitor_host` cleared or replaced). It was never meant to touch anything else, and it doesn't — but `register_visitor/2`'s own `visitor_snapshot/1` (the audit payload for the `"visitor.registered"` action, written once, at registration) stored the visitor's full name, phone, email and host in `audit_logs.after`, and nothing in the system ever revisits that row. So a visitor's personal data outlived the purge indefinitely, in a table FR-VIS-04/NFR-PRIV-01 were never written with in mind, defeating the retention guarantee even though the `people` table itself was behaving exactly as designed.

**Fix**, `lib/salvorion/roster.ex`: `visitor_snapshot/1` (used only for `"visitor.registered"`, never for `"person.created"`/`"person.updated"`, which still carry full detail for staff/student audit history — those aren't retention-limited) now returns `%{person_id:, pass_code:, visitor_expires_at:}` only — no name, phone, email or host, ever. **Accepted trade-off:** this is a real, deliberate reduction in forensic detail — an admin reviewing the audit log for who registered a given visitor and when can no longer see that visitor's name directly in the log; they resolve `person_id` against the current `people` row instead (which itself will read as the anonymised placeholder once purged, by design). This was judged the right trade for a field expressly scoped to retention-limited data.

**Known, accepted residual gap, not fixed here:** `ReportDelivery`/`ReportRun` — a visitor who appears in an activation's unaccounted list or manual sign-in log before their pass expires is named in that activation's generated PDF and in the email sent to every active report recipient. Neither the PDF file nor the sent email can be recalled once delivered, and nothing purges the PDF (Prompt 11 already flagged local filesystem storage as its own Release-1 limitation, separately). This is a smaller, different problem — the report is a legitimate compliance record naming who was and wasn't accounted for during an actual activation, not an incidental audit-log leak of registration details — and addressing it (report retention/redaction policy) is a product decision for a later pass, not a mechanical fix.

Two new tests in `roster_visitors_test.exs`: registering a visitor with name/phone/email/host supplied asserts none of those fields (or their values) appear anywhere in the resulting `visitor.registered` audit row's `after` payload; and registering then purging a visitor confirms the *original* registration audit row is byte-for-byte unchanged by the purge — nothing further needed to happen to it at purge time, because it was never written with personal data to begin with.

## Consistency audit follow-up (Document 25/26, Task 1): people-lookup routes widened to all four roles

`GET /api/people`, `GET /api/people/:id` and `GET /api/people/lookup` previously allowed `admin`, `osh_officer` and `warden` — `report_viewer` was excluded, with no documented reason and no corresponding row in Document 10 §1 (the roster isn't a §1 permission row at all; access was always meant to follow §2's data classification, "Directory information ... visible to any authenticated user role in the course of their duties"). This was a real gap, not a judgment call: `report_viewer`'s whole purpose (Document 02 §4, Document 05 §2.3) is read-only visibility, and `docker/powersync/sync-config.yaml`'s `people` stream already replicates the full roster unconditionally to every authenticated role, `report_viewer` included — the HTTP route was narrower than the data that role's own client already has.

**Fix:** `SalvorionWeb.RBAC`'s three rows changed from `[@admin, @osh, @warden]` to `@all_roles`. No context-layer change: `Roster.list_people/1`, `get_person!/1` and `get_person_by_id_number/1` already return the same directory-information shape for everyone. Tests added to `person_controller_test.exs` confirming `report_viewer` now succeeds on all three routes.

## Consistency audit follow-up (Document 25/26, Task 2): the unaccounted-list route narrowed, its four dashboard siblings left alone

`GET /api/activations/:id/dashboard/unaccounted` previously shared one role list (`[@admin, @osh, @viewer]`) with `summary`, `departments`, `faculties` and `zones` — copied from those four rather than read on its own. Document 10 §1 has its own row for this, "View unaccounted list (all zones)", and it is explicit: Report Viewer is **No** there, distinct from "View live dashboard"'s Yes-for-Report-Viewer (read-only). The distinction is real, not pedantic: the other four routes return aggregate counts and rates — numbers that describe a situation without naming anyone. Unaccounted names specific individuals, by name, in real time, during a live activation — operationally sensitive in a way an aggregate count isn't, and the one dashboard read a Report Viewer (someone with no operational role in an actual emergency) has no documented need to see live.

**Fix:** `SalvorionWeb.RBAC`'s row for this one route narrowed to `[@admin, @osh]`; the other four dashboard rows are untouched. `report_viewer` still sees every other dashboard figure, and still lists/downloads a *closed* activation's report — which itself includes the unaccounted list as a historical record, not a live one (see the next entry) — so nothing about the read-only role's actual purpose is reduced, only its access to one specific live-and-identifying feed. Test added to `accountability_reads_controllers_test.exs` confirming `report_viewer` gets 200 on the four siblings and 403 specifically on unaccounted.

## Consistency audit follow-up (Document 25/26, Task 3): report_viewer's report access — already correct, now documented

Finding 2.7 of the consistency audit (Document 25) flagged that `report_viewer` could list and download an activation's generated reports via `SalvorionWeb.RBAC` (`GET /api/activations/:id/reports` and its `/download` route both already list `@viewer`), while Document 10 §2's data-classification table only named "Administrator and OSH Officer roles" for generated-report access — a documentation gap, not a code gap: the code was already right; the security document just hadn't caught up to it, and a reviewer reading §2 in isolation would have concluded `report_viewer` was over-privileged when it wasn't.

**Closed as: already correct; document updated.** `docs/10-security-design.md` §2's "Generated reports (PDF)" row now names the Report Viewer role explicitly, alongside a one-line reminder of what stays Administrator/OSH-Officer-only (managing recipients, manually regenerating). No code change — `RBAC`'s existing rows are the intended behavior, per Document 02 §4's own description of what the read-only login is for.

## Consistency audit follow-up (Document 25/26, Task 4): a warden's roll_call marks and contradiction resolutions are now scoped to their own zone/area

Document 10 §1's "Conduct roll call" row reads "Own assigned zone/area only" for Safety Warden — but nothing enforced it as a *write* restriction before this fix. `Accountability.ingest_event/2` let an authenticated warden post a `roll_call` mark for any person in any zone, and `resolve_contradiction/3` let them resolve any contradiction anywhere; only the *read* side (`list_roll_call/2`, via `Scope.warden_scope/2`) was ever scoped. A warden could not see a person outside their zone on their own roll-call list, but could still mark that person absent or excused directly, or resolve their flagged contradiction, by supplying a `person_id` the API never checked against the warden's own assignments.

**Fix:** `Accountability.person_in_warden_scope?/3` (new, public) answers "is this person in this warden's scope for this activation," using the *exact same* rule `list_roll_call/2` already uses — `Scope.warden_scope/2` (pinned to `activation.started_at`, "a warden's scope is fixed at activation start," above) plus `Scope.in_scope_person_ids_query/2`'s roster-or-event-location rule (Prompt 7) — reused, not reimplemented, so "can this warden roll-call this person" and "does this warden's own list show this person" can never silently drift apart. `ingest_event/2` now calls it, but *only* when `kind == "roll_call"` and the recording user's role is `warden`; a scope failure returns `{:error, :outside_warden_scope}`, mapped to 403 in `FallbackController`. `resolve_contradiction/3` gets the identical check, for the same reason: confirming a contradiction is part of conducting that zone's roll call, not a separate, unscoped action.

**Deliberately not restricted:** `scanned`, `manual` and `visitor_registered` — sign-in remains legitimate anywhere a person actually is, campus-wide; the whole point of a shared assembly-point sign-in station is that anyone can walk up to any point, not only the ones in their assigned warden's own zone. `override` and `contradiction_resolved`-via-other-paths are already `admin`/`osh_officer`-only via the pre-existing `check_override_permitted/1`, so this new restriction structurally can never apply to a role that isn't a warden recording a `roll_call` — there is no code path where an admin or osh_officer's roll-call mark, from any zone, is affected. Tests added to `accountability_test.exs` (context level: Zone 5 warden vs. a Zone 8 person, rejected for `roll_call`, accepted for `scanned`, an admin unaffected either way, and the same scoping applied to `resolve_contradiction/3`) and `event_controller_test.exs` (one HTTP-level test confirming the 403 end to end through `FallbackController`).

## Consistency audit follow-up (Document 25/26, Task 5): a settings API route, closing finding 3.6

Finding 3.6 of the consistency audit: nothing could change `student_accountability_rule` or `visitor_retention_days` from the API — `Settings.put_setting/3` existed but had no route — and an invalid `student_accountability_rule` value written any other way (a future admin screen, a manual `iex` session) would surface only as an `ArgumentError`/500 the moment an activation next started (`Accountability.initialise_for_activation/1`), not as a rejected write at the time the bad value was actually set.

**Fix:** `GET /api/settings` (every known key, current value or documented default) and `PATCH /api/settings/:key` (`admin`/`osh_officer`, matching Document 10 §1's "Change system settings" row), both in the new `SalvorionWeb.SettingController`. `PATCH` validates before calling `put_setting/3`, never after: `student_accountability_rule` must be `"signed_in_only"`, `"all_enrolled"`, or `"timetable_expected"` — anything else is a 422, nothing written; `visitor_retention_days` must be a positive integer, same treatment for anything else. `"timetable_expected"` is deliberately *not* rejected outright — Release 1 doesn't implement it, but nothing says a future release won't, so the settings layer still lets it be stored — but the response carries an explicit warning that it is not yet functional and that starting an activation under it will fail, so choosing it here never silently reads as fully supported. `id_barcode_parser` and `offline_login_grace_hours` are listed in `GET /api/settings` too (both are documented known keys per `Setting`'s own moduledoc) but carry no asserted default and no shape validation on `PATCH`, since — per finding 7.4 — neither is actually read by any code path yet; inventing a default or a validation rule for either here would be asserting a requirement no document or code path has ever settled. Tests added in the new `setting_controller_test.exs`: every known key listed with correct defaults, a written value reflected back, both invalid-value cases rejected with nothing persisted, the `timetable_expected` warning present, an unknown key rejected, and the route's RBAC (`warden`/`report_viewer` get 403).

## Consistency audit follow-up (Document 25/26, Task 6): a visitor who never reaches an assembly point cannot appear on any unaccounted list — by design, not a bug

Plain statement, for anyone who isn't reading this file line-by-line with the code open: if a visitor is registered — at reception, in advance, or anywhere away from the assembly point itself — but the emergency arrives before they ever physically sign in at a zone or area, Salvorion will never show them as "unaccounted," "missing," or on any non-compliance list, for any activation, ever. This is not a defect to file a ticket against. It is a direct, permanent consequence of what "unaccounted" is defined to mean in this system.

**Why.** "Unaccounted" only has meaning for someone the system *expected in advance* — Document 06's own note: "it is what makes 'unaccounted' a meaningful status: someone not expected is simply absent from the count, not flagged as missing." Staff and students are expected because there's a roster to expect them against (their usual area, their department's areas). Visitors have no roster entry at all — `Roster.register_visitor/2` creates their `Person` row at the moment of registration, with no location data and nothing upstream that could have listed them as "due to be somewhere" beforehand. `Accountability.initialise_for_activation/1` never creates an `ExpectedPresence` row for a visitor (see "expectation rules for Release 1," above: "Visitors: never expected in advance; their first event creates their `PersonStatus` row"), so there is structurally nothing for "unaccounted" to attach to before that first event happens. FR-VIS-03 ("Visitors shall be included in participation counts and non-compliance lists in the same way as staff and students") is met for every visitor who *does* sign in — they appear as `present`, on every count, exactly like anyone else — but a visitor who registers and then never signs in simply generates no accountability event at all, and a system with no event and no expectation for that person has no basis to conclude anything about where they are. This was also already flagged, from a different angle, during the consistency audit itself (Document 05 Appendix A's escalation note: "Reported, not automated, in Release 1" — OSH's manual escalation process, Document 09 §4, likewise only ever operates on the unaccounted list the system actually produces).

**What this means operationally.** OSH cannot rely on Salvorion's unaccounted list to catch a visitor who registered but then wandered off before an activation, or who was on campus without ever having registered at all. Any process for accounting for expected *visitors specifically* (as opposed to visitors who happen to sign in) is outside what this system does in Release 1, and would need a different mechanism entirely — for instance, a host being asked directly whether their registered guest is accounted for — not a Salvorion feature request, since there is no roster-equivalent for visitors this system could ever expect them against without changing what a visitor registration fundamentally is.

## Consistency audit follow-up (Document 25/26, Task 7): deactivated users are now rejected symmetrically with revoked devices

`devices.revoked_at` was checked on every request (`Guardian.verify_access_token/1`) and by `ActivationChannel`'s periodic self-check; `users.active` was checked nowhere except at login (`Accounts.authenticate_user/2`). A user deactivated mid-session (`Accounts.deactivate_user/2`, e.g. an administrator offboarding someone) kept full API access for up to 15 minutes (their access token's remaining life) and kept receiving Channel pushes for up to 5 minutes past that on any already-open connection — the exact gap device revocation already had before Prompt 12's channel self-check closed it for devices, just never closed for the user's own account status.

**Fix, made once, in the one place both callers already share:** `Accounts.user_deactivated?/1` (new, mirrors `device_revoked?/1`'s naming and "true when it does not exist or is in the bad state" shape) is now called from `Guardian.verify_access_token/1`, alongside the existing device check. Because `SalvorionWeb.Plugs.Authorize` and `SalvorionWeb.UserSocket.connect/3` already both call `verify_access_token/1` (the Prompt 12 refactor that made this the one shared place token validity lives), this single change closes the gap for both the HTTP plug and new socket connections at once — a deactivated user's still-unexpired token is now rejected (401) on the very next request or connection attempt, not just at their next login. `ActivationChannel`'s `session_invalid?/1` (the Task 3 periodic self-check) gained the same `Accounts.user_deactivated?/1` call alongside its existing device-revocation and token-expiry checks, so an already-open channel now also terminates (pushing `session_revoked`, same as a device revocation) within one check interval of the user being deactivated, not just a newly-opened one.

There is no pre-existing "three tiers" table in this file to update — the Prompt 12 entries described the HTTP-immediate / Channel-≤5-minute / PowerSync-≤15-minute comparison in prose, for device revocation specifically, without a literal tiered list. That comparison now has a fourth condition riding along both of the two checked conditions it already covered: `users.active`, like `devices.revoked_at`, is checked immediately on every HTTP request and socket connect attempt, and within 5 minutes on an already-open channel. Tests added: `auth_controller_test.exs` (a deactivated user's existing token now gets 401 on the next `GET /api/auth/me`, mirroring the existing revoked-device test immediately above it), `user_socket_test.exs` (a deactivated user cannot open a new socket connection), and `activation_channel_test.exs` (an already-open channel receives `session_revoked` and terminates within one self-check of the user being deactivated mid-connection, using the same `send(socket.channel_pid, :check_revocation)` test-acceleration technique the existing device-revocation test already uses).

## Scaffolding choices (for reference)

- Generated with `mix phx.new . --app salvorion --module Salvorion --no-html --no-assets --no-live --binary-id`
  (Phoenix 1.8.13). API-only; UUID primary keys everywhere to match the
  domain model; Swoosh mailer kept for later email delivery.
- PowerSync uses **Postgres** for sync-bucket storage (a separate database,
  `powersync_storage`, on the same Postgres 16 server), so no MongoDB container.
- `docker/powersync/sync-config.yaml` was, at scaffolding time, an empty
  Sync Streams (edition 3) placeholder, with real streams deferred until
  the domain schema landed. **Superseded by Prompt 10:** the file is no
  longer empty or a placeholder — it now holds the full set of real stream
  definitions (every `*_warden_*`, `people`, `activations`, `users`-via-
  `sync_safe_users`-column-list, etc. — see the "PowerSync sync config
  (Prompt 10)" entries above for the decisions made while writing them).
