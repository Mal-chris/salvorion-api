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

## Scaffolding choices (for reference)

- Generated with `mix phx.new . --app salvorion --module Salvorion --no-html --no-assets --no-live --binary-id`
  (Phoenix 1.8.13). API-only; UUID primary keys everywhere to match the
  domain model; Swoosh mailer kept for later email delivery.
- PowerSync uses **Postgres** for sync-bucket storage (a separate database,
  `powersync_storage`, on the same Postgres 16 server), so no MongoDB container.
- `docker/powersync/sync-config.yaml` is an empty Sync Streams (edition 3)
  placeholder; real streams are defined once the domain schema lands.
