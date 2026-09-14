# Prompt 10: PowerSync Sync Configuration

**Document:** 22 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 12 (the sync-rules half; the write endpoints it depends on were built in Prompt 9)
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 13 September 2026

---

## Why this needs its own prompt, and what is genuinely uncertain

`docker/powersync/sync-config.yaml` is currently an empty placeholder, noted in DECISIONS.md as "Sync Streams (edition 3)" without confirmation that this is actually the config mechanism the installed image (`journeyapps/powersync-service:1.26.0`, Open Edition, Postgres bucket storage) supports as stable. This prompt does not assume an answer. Its first task is to find out, against PowerSync's real, current documentation for that exact version, and proceed from there — the older bucket-based "Sync Rules" YAML format and the newer "Sync Streams" mechanism are configured differently, and guessing wrong here would produce a file that looks plausible and does nothing.

Two things are also genuinely hard, not just unresearched, and are called out so Claude Code does not silently smooth over them:

- **A warden's sync scope cannot perfectly match `Accountability.Scope`'s API-side logic.** The API's `list_roll_call/2` is computed fresh, in Elixir, against live data. PowerSync's scoping has to be expressed as a query (or set of queries) that Postgres can evaluate to decide bucket membership. The roster half of the scope rule (a person's usual area or department-linked areas) is straightforward to express this way. The event-driven half (rule ii from Document 08's DECISIONS entry — a person is in scope wherever they actually signed in, even with no roster location) is expressible too, since `area_id`/`assembly_point_id` are literal columns on `accountability_events`, but it needs its own query, and any difference between the two must be written down, not assumed away.
- **PowerSync validates the JWT's signature and expiry. It has no idea what `devices.revoked_at` is.** A revoked device's token remains valid to PowerSync until it naturally expires (15 minutes), even though `SalvorionWeb.Plugs.Authorize` would reject it immediately on the API side. This is a real, if bounded, gap between the two enforcement points and belongs on the list of things for OSH to know about, not just in a code comment.

Have Claude Code read `docs/03-technical-foundation.md` section 2.2, `docs/07-c4-architecture-diagrams.md` (the PowerSync boundary and the read/write split), `docs/10-security-design.md` sections 1 and 6, and `docs/DECISIONS.md` in full before starting.

---

## The prompt

```
This is the tenth step in building Salvorion. Prompts 1–9 (complete)
built every context and its HTTP layer. This prompt configures
PowerSync: which rows each authenticated client may read, scoped by
role and, for wardens, by their zone/area assignment. It does not touch
Elixir application code except where noted in Task 3.

Read docs/03-technical-foundation.md section 2.2,
docs/07-c4-architecture-diagrams.md, docs/10-security-design.md sections
1 and 6, and docs/DECISIONS.md in full before starting.

TASK 0: Confirm the config mechanism before writing anything
Check PowerSync's official documentation for the exact behaviour of
journeyapps/powersync-service:1.26.0 in Open Edition with Postgres
bucket storage (already running — docker-compose.yml, PS_STORAGE_SOURCE_URI).
Determine definitively whether this version's stable, supported
configuration is the bucket-based "Sync Rules" YAML format or "Sync
Streams", and confirm the exact file(s) and schema the running
powersync.yaml expects it to load from (currently pointed at
docker/powersync/sync-config.yaml). Report which one, with a link or
citation to the documentation you used, before proceeding to Task 1.
If the documentation is ambiguous or the running service's own startup
logs/error output settle it empirically (e.g. it refuses to boot against
one format but accepts the other), say so and show that evidence.

TASK 1: Global reference data
Every authenticated user (any role) syncs, in full and unconditionally:
faculties, departments, programmes, assembly_points, zones, areas,
department_areas, settings. These are small, non-sensitive (Document 10,
section 2: "directory information", "Internal"), and needed offline by
every client regardless of role.

TASK 2: The full roster, for offline scan resolution
Every authenticated user syncs the full people table. This is required
for NFR-OFF-01: a warden scanning an ID card with zero connectivity
must resolve id_number -> person locally, which is impossible unless
the roster is already on the device. Confirm no column on people is
sensitive enough to exclude (it is not — no password, no visitor
contact information beyond what Document 10 already classifies as
Internal). Visitors with purged personal details (Prompt 8) sync too;
their anonymised name is not sensitive by design.

TASK 3: A safety view for the user's own record — defense in depth
users.password_hash must never be replicated to a client, under any
circumstance, even a future misconfiguration of a sync rule. Do not
rely solely on writing the sync query correctly. Create a Postgres view
(a new migration, numbered after the existing ones):
  CREATE VIEW sync_safe_users AS
    SELECT id, email, role, active, inserted_at, updated_at FROM users;
Sync from this view, scoped to the requesting user's own row only
(matched against the JWT's sub claim, whatever PowerSync's
documented mechanism for reading JWT claims turns out to be — confirm
this mechanism against the real documentation, do not guess the syntax).
This view is a second, independent barrier: even if a future sync rule
query were carelessly changed to select from users directly, the
password_hash column would need to be added to this view first, which
is a visible, reviewable change, not a silent one.

TASK 4: Activations
Every authenticated user syncs activations and activation_zones, in
full, unconditionally, for the same reason as Task 1 — knowing whether
a drill is active, and its type, is not sensitive, and every role
(warden included) needs it without a network round-trip the moment one
starts.

TASK 5: Accountability data — scoped by role
For admin, osh_officer and report_viewer (determine how to read the
role claim from the verified JWT per Task 0's findings — it was placed
there by Guardian's build_claims/3 in Prompt 2): sync
accountability_events, person_statuses and expected_presences in full,
unconditionally. The dashboard needs the whole picture.

For warden: scope all three to the union of two sets, matching
Accountability.Scope's two rules as closely as PowerSync's query
mechanism allows:
  (a) rows for people whose roster location (usual_area, or an area
      linked via department_areas to any of the person's departments)
      falls within the warden's currently effective assignments
      (warden_assignments, filtered by date range against the CURRENT
      time — note in DECISIONS.md that this is necessarily "now", not
      "activation start" the way the API-side Accounts.
      effective_warden_assignments/2 pins it; a sync client's visible
      rows can shift if an assignment changes, even though the API's
      own roll-call answer for an in-progress activation would not —
      write down this discrepancy plainly, it is a real difference
      between the two layers, not a bug to silently fix here); PLUS
  (b) rows where the event's own area_id or assembly_point_id falls
      within the warden's currently effective assignments — this is
      the literal, queryable half of Scope's rule (ii), covering
      walk-ins with no roster location.
Also sync warden_assignments, scoped to the requesting user's own rows
only (a warden does not need to see others' assignments; admin/
osh_officer see all, for the future admin screen).

TASK 6: Write the explicit gap into DECISIONS.md
Record: PowerSync authenticates a connection by verifying the JWT's
signature and expiry only. It has no knowledge of devices.revoked_at.
A device revoked via POST /api/devices/:id/revoke stops working against
the Phoenix API immediately, but its still-unexpired access token
(up to 15 minutes old) continues to sync via PowerSync until that token
naturally expires. State the bound precisely (worst case 15 minutes,
matching the access token TTL) and that no code change in this prompt
addresses it — it is a property of JWT-based auth generally, worth OSH
knowing, and a candidate for a future short-TTL-plus-revocation-check
webhook if PowerSync's self-hosted edition ever supports one.

VERIFICATION
Building a full Flutter client is out of scope (Stage C). Verify the
actual sync protocol directly instead, using a minimal temporary test
client — a short Node.js script using PowerSync's official JS/web
client library (@powersync/web or equivalent — confirm the correct
package against real documentation), connecting with a real JWT from
this project's own /api/auth/login, is the honest way to prove this
works without fabricating results. This script is a verification tool,
not part of the application — put it under a new top-level tools/
directory (not lib/, not test/), and say so.

 1. Task 0's findings, in full, before anything else.
 2. Confirm the powersync container picks up the new config without
    error (its logs) after `docker compose restart powersync`.
 3. Using the test client and O1's (osh_officer) token: connect, and
    show that global reference data, the full roster, all activations,
    and ALL accountability_events/person_statuses/expected_presences
    (across every zone) replicate. Row counts, not just "it worked".
 4. Using W5's (warden, Zone 5) token, with an active campus activation
    and at least one event in Zone 5 and one event in a different zone
    (Zone 8) already ingested via the API: confirm W5's client receives
    the Zone 5 event's person_status but does NOT receive the Zone 8
    one. Show both the received row count and, explicitly, that the
    Zone 8 person's row is absent, not merely unobserved (query the
    local SQLite the test client builds and show it directly).
 5. Confirm W5's client receives the full roster and reference data
    (Tasks 1, 2, 4 are unconditional) despite the accountability
    scoping in item 4 — this proves the scoping is specific to
    accountability data, not a blanket restriction.
 6. Query the client's local copy of the synced user data and confirm
    no password_hash field or column exists anywhere in it — not null,
    not absent-by-coincidence, structurally impossible because the
    source view never had the column.
 7. Revoke W5's device (Prompt 9's endpoint), reconnect the test client
    with the same still-unexpired token, and confirm it still
    syncs — demonstrating the gap from Task 6 empirically rather than
    only describing it. Then wait for the token to expire (or use a
    short-lived test token) and confirm the reconnect is then rejected.
 8. Every file created or modified, and the exact text added to
    docs/DECISIONS.md.

Stop after verification. Do not start the Reporting context.
```

---

## What to check yourself

1. **Task 0 is the load-bearing item. Read it before anything else in the report.** If the config format was wrong, everything after it may have "looked" like it worked (a file was written, the container didn't crash) while replicating nothing or replicating everything unconditionally. The container's own logs on a bad config are usually explicit; make sure the report shows them rather than asserting success.
2. **Item 4 is the actual proof of the whole prompt.** A warden receiving too much is a privacy and clutter problem; a warden receiving too little is a safety problem, since it means a person nobody sees. Confirm both directions were tested, not just that Zone 5 data arrived.
3. **Item 6 needs to convince you structurally, not just empirically.** "I checked and password_hash wasn't there" is weaker than "the view never selects it, so it cannot be there." Read Task 3's migration yourself.
4. **Item 7 is the one finding in this prompt that is genuinely a live, present-tense limitation, not a historical note.** Make sure it lands on the same OSH-facing list as the other operational decisions — this is arguably the most technical one to explain to a non-technical audience, and worth thinking now about how to phrase it plainly when that note gets written.
5. **If Task 0 concludes the installed PowerSync version cannot express Task 5's warden scoping at all** (rather than merely differently from the API), stop and tell me before accepting a workaround — that would be a real architectural finding, not something to route around quietly.
