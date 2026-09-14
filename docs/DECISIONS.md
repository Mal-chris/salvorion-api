# Decisions and notes for upcoming work

Recorded during project scaffolding so they are not lost. Each section names
the prompt that implemented it, or says it is pending.

## Guardian must use an asymmetric signing key (RS256 or ES256)

Do **not** use Guardian's default HS512 shared secret. PowerSync authenticates
clients by verifying their JWT against a JWKS endpoint that Phoenix will expose
at `/.well-known/jwks.json`. A symmetric key cannot be published as a JWKS
(publishing it would let anyone forge tokens), so tokens must be signed with an
RSA or EC private key and the matching public key served from that endpoint.
The PowerSync service config (`docker/powersync/powersync.yaml`) already points
`client_auth.jwks_uri` at that URL via `POWERSYNC_JWKS_URL`.

## Client offline outbox via PowerSync upload queue

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
shape from the Locations, Organisation and Settings permissions built in
Prompt 3, where OSH Officer and System Administrator are both permitted
("Manage assembly points, zones, areas", "Change system settings", etc.
are Yes/Yes). Whoever wires the RBAC route mapping for the Activations
routes (a later prompt) must not default to "same access as everything
else OSH Officer can do" — System Administrator does not get a pass on
starting or closing an activation, even though it does on almost every
other OSH-managed resource.

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
`"accountability.late_event_after_report"` is written for either class, so
the Reporting context can offer a regenerate (FR-REP-05).

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
  students via `programme.faculty_id`. Nil (which is every faculty in the
  current dev data — Document 01, section 9) groups as `"(no faculty)"`.
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
in a comment next to the row itself. Four don't, or extend one beyond its
literal reading, each recorded here as well since a reviewer scanning
`docs/10-security-design.md` side-by-side with the matrix would otherwise
wonder where they came from:

- **`GET /api/faculties`/`/departments`/`/programmes`, `GET
  /api/assembly-points`/`/zones`/`/areas`, `GET /api/people`.** Not a
  section 1 row at all — section 1 only lists *write* permissions for these
  resources ("Manage assembly points, zones, areas", "Manage departments,
  faculties, programmes"); reading them is covered instead by section 2's
  data classification table ("Directory information ... visible to any
  authenticated user role in the course of their duties"). All reads here
  are `@all_roles`.
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

`Reporting.finish_run_if_complete/1` (called once per `DeliverReportWorker` job as it settles) can, if two of a run's deliveries finish at nearly the same moment under the `:reports` queue's concurrency of 2, both observe "zero deliveries still pending" and both call `Activations.mark_activation_reported/1`. The second call is a harmless no-op: `Activation.mark_reported_changeset/1` requires `status == "closed"` on the struct it's given, which is no longer true by the time the second call's changeset is built from a reload, so it returns a changeset error that `finish_run_if_complete/1` logs and discards rather than propagating. Not fixed with a lock, for the same reason the synthetic-roster-ID race (Prompt 4) and the visitor-pass-code collision handling (Prompt 8) weren't: a low-probability duplicate-audit-row outcome on a non-safety-critical path, not a correctness or data-loss risk.

## Reporting (Prompt 11): generated report storage is a Release 1 limitation, recorded for the deployment prompt

`priv/generated_reports/{activation_id}-{report_run_id}.pdf` (Task 4) is local filesystem storage under the application's own `priv/` directory — fine for a single-instance deployment (Document 08 section 6's initial deployment diagram: one application VM), but it will not survive a redeploy, does not work across multiple application instances, and has no backup story of its own (unlike the managed Postgres database). Before any deployment beyond the current single-VM plan, this needs to become real object storage (S3 or equivalent) with `ReportRun.pdf_path` changed from a local path to an object key/URL. Not addressed in this prompt — recorded here for whoever does Document 08 section 6's later "Stage D: deployment" work (`Salvorion.Reporting.render_report_pdf/1`'s caller, `GenerateReportWorker`, is the only place a storage-layer change would need to happen; `Reporting.report_pdf_path/2`'s signature could stay the same).

## Reporting (Prompt 11): Amazon SES is configured but unverified

Task 6 asked for `Swoosh.Adapters.AmazonSES` in production only, guarded by `config_env() == :prod` in `config/runtime.exs` exactly like the Guardian key path — done, and `ex_aws`/`ex_aws_ses` were added to `mix.exs` as real dependencies for it. Per the prompt's own instruction, no attempt was made to actually send email anywhere in this prompt's verification: there are no AWS credentials in this environment, `config/runtime.exs`'s SES branch only ever runs when `config_env() == :prod` (never in dev or test, confirmed — `mix compile`/`mix test` do not evaluate that branch and need no `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` to succeed), and the two new dependencies compile without requiring any credential to be present. **The interface is complete and swappable via config alone; SES itself is unverified until real AWS credentials exist.** Whoever first deploys to production should send one real report email deliberately, with SES in sandbox mode against a verified test address, before relying on FR-REP-03's "within 15 minutes" for a real activation.

## Reporting (Prompt 11): a pre-existing `async: true` / advisory-lock flake, one file fixed, the pattern flagged rather than swept

Running the full suite after adding this prompt's tests, `activation_controller_test.exs` (pre-existing, unrelated to Reporting) intermittently failed with `Postgrex.Error ... query_canceled` inside `Activations.acquire_start_lock/1`. Cause: `start_activation/2` serialises every caller on one fixed Postgres advisory-lock key (`Activations`' own moduledoc explains why — campus-wide activations have no `activation_zones` rows for a partial unique index to key off), and this test file runs `async: true` despite calling `start_activation/2` in nearly every test — `ActivationsTest` itself is deliberately `async: false` for exactly this reason, but that reasoning was never applied to the controller test. This prompt's own new tests (several real-Gotenberg-HTTP-bound `async: false` tests, run serially) lengthened the full suite's wall-clock time enough to make the pre-existing race actually surface, which is why it looked at first like a Prompt 11 regression rather than a latent gap `activation_controller_test.exs` always had.

Fixed the one file that actually failed (now `async: false`, matching `ActivationsTest`'s own precedent), and confirmed by rerunning the full suite. **Not swept further**: `event_controller_test.exs`, `visitor_controller_test.exs`, `accountability_reads_controllers_test.exs` and `roster_visitors_test.exs` all also call `start_activation/2` under `async: true` and share the same latent risk, but did not fail in this run and belong to earlier prompts outside Reporting's scope — recorded here so whoever next sees an unexplained `query_canceled` failure in one of them knows the cause immediately rather than re-diagnosing it, rather than "fixed" speculatively across files this prompt has no other reason to touch.

## Reporting (Prompt 11): closing an activation must itself enqueue `GenerateReportWorker` — not stated by name in Task 5, required by FR-REP-01 and Document 08 section 4

Task 5 specifies what `GenerateReportWorker` does once it has an `activation_id`, and Task 7 specifies the *manual* regenerate trigger (`regenerate_report/2`), but nothing in the prompt's task list says who enqueues the worker the first time, automatically, when an activation closes. FR-REP-01 ("The system shall automatically generate a report when an activation is closed") and Document 08 section 4's own sequence diagram are explicit that this happens as part of the close request itself ("`API->>Oban: Enqueue GenerateReportJob(activation_id)`", drawn as a step of the `PATCH /activations/:id` flow, immediately after `Activations` reports the transition succeeded) — so this was read as a real requirement to implement, not an optional nicety, even though no task named it directly.

`SalvorionWeb.ActivationController.close/2` now enqueues `GenerateReportWorker` immediately after `Activations.close_activation/2` succeeds. Deliberately **not** placed inside `Salvorion.Activations.close_activation/2` itself, matching the sequence diagram's own layering (the enqueue is drawn as the API's action, not the Activations context's) and keeping `Salvorion.Activations` free of any dependency on `Salvorion.Reporting` — the dependency arrow already runs the other way (`Reporting` depends on `Activations` for `get_activation!/1` and `mark_activation_reported/1`), and a context reaching back into a context that depends on it would be a real layering smell. Caught by walking through this prompt's own verification script end-to-end against a real activation, rather than by anything the automated test suite would have caught on its own (every Reporting/worker test in this prompt calls `Activations.close_activation/2` directly, bypassing the controller, so none of them would have noticed this endpoint never enqueued anything) — a reminder that a context-level test suite proving each piece works in isolation does not prove the pieces are actually wired together end to end.

## Scaffolding choices (for reference)

- Generated with `mix phx.new . --app salvorion --module Salvorion --no-html --no-assets --no-live --binary-id`
  (Phoenix 1.8.13). API-only; UUID primary keys everywhere to match the
  domain model; Swoosh mailer kept for later email delivery.
- PowerSync uses **Postgres** for sync-bucket storage (a separate database,
  `powersync_storage`, on the same Postgres 16 server), so no MongoDB container.
- `docker/powersync/sync-config.yaml` is an empty Sync Streams (edition 3)
  placeholder; real streams are defined once the domain schema lands.
