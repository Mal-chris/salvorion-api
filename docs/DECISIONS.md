# Decisions and notes for upcoming work

Recorded during project scaffolding so they are not lost. None of these are
implemented yet.

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

Offline devices upload after connectivity returns, which may be after the
OSH Officer has closed the activation. `Accountability.ingest_event/2`
accepts an event for a `closed` or `reported` activation if its
`client_timestamp` is no later than `closed_at` **plus 5 minutes**
(`@late_event_tolerance_seconds`, a constant; to become a setting if OSH
wants it tunable). Later than that it is rejected with
`{:error, :activation_closed}`. An accepted late event is stored and the
person's status re-derived exactly as if it had arrived on time. If the
activation is already `reported`, an additional audit row with action
`"accountability.late_event_after_report"` is written so the Reporting
context can offer a regenerate (FR-REP-05). This is the one place
`client_timestamp` is consulted; it is never used for ordering (I2).

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

## Scaffolding choices (for reference)

- Generated with `mix phx.new . --app salvorion --module Salvorion --no-html --no-assets --no-live --binary-id`
  (Phoenix 1.8.13). API-only; UUID primary keys everywhere to match the
  domain model; Swoosh mailer kept for later email delivery.
- PowerSync uses **Postgres** for sync-bucket storage (a separate database,
  `powersync_storage`, on the same Postgres 16 server), so no MongoDB container.
- `docker/powersync/sync-config.yaml` is an empty Sync Streams (edition 3)
  placeholder; real streams are defined once the domain schema lands.
