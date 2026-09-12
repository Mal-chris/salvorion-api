# Consistency Audit: Documents 01 to 12 and the Ecto Package

**Document:** 13 of the project record
**Date:** 11 September 2026
**Scope:** Every project document produced so far (01 Charter through 12 Stage A Prompt 1) and the Ecto migrations and schemas in `salvorion-ecto-schema.zip`, cross-checked against each other for contradictions, stale content, gaps, and naming drift.
**How to read this:** Findings are ranked by consequence, not by how easy they are to fix. Section 1 needs a decision from you before Prompt 2. Section 2 is gaps that would surface as bugs or missing features during development. Section 3 is stale content left behind by the NestJS to Phoenix switch. Section 4 is naming drift. Section 5 is minor. Each finding names the documents involved and the recommended resolution.

---

## 1. Architectural contradictions that need a decision before Prompt 2

### 1.1 Three documents describe three different write paths for offline events

- **Document 04, section 4** says PowerSync replaces the hand-built outbox and sync worker (Stage C item 17 is "replaced by: integrate the PowerSync Flutter SDK").
- **Document 07, section 2** says writes "do not go through PowerSync at all"; they are "queued by the client and simply retried against the API."
- **Document 08, section 2** draws a hand-built "Local Outbox (Drift/SQLite)" and a "Sync worker" that pushes events to the API on reconnect, which is exactly the design 04 said was replaced.

These cannot all be true. PowerSync's standard pattern is that local writes go into its own CRUD upload queue, and the app supplies a backend connector (`uploadData`) that sends each queued write to your API. That is neither "writes bypass PowerSync" (07) nor "a separate Drift outbox" (08).

**Recommendation:** adopt PowerSync's upload queue as the outbox. The Flutter app writes the event locally through PowerSync, PowerSync queues it, and the connector's `uploadData` POSTs it to Phoenix with the `client_uuid` intact, so the idempotency design survives unchanged. Drift is then used only for client-only data, which is what 04 and 07 section 4 already say. Update 07 section 2 (the "do not go through PowerSync" bullet) and redraw 08 section 2 with PowerSync's queue in place of the Drift outbox.

### 1.2 The web dashboard's read path is drawn two different ways

- **Document 07, container diagram** and **05 section 5.4**: the web dashboard talks to Phoenix over HTTPS and WebSocket (Phoenix Channels).
- **Document 08, section 1**: the dashboard updates via "PS-->>Web: Reactive query updates dashboard," i.e. through PowerSync.
- **Document 07, section 3** has a Phoenix Channels component that "broadcasts on PersonStatus change."

Both mechanisms are described as the dashboard's live-update path. Since the web dashboard is the same Flutter codebase as the mobile app and PowerSync supports Flutter web, the simplest consistent design is that both clients read through PowerSync, and Phoenix Channels are kept only for pushes that are not row replication (for example the contradiction flag returned to the warden in 08 section 3, if you want it pushed rather than polled).

**Recommendation:** decide one read path for the dashboard. If PowerSync, update 05 section 5.4, 07 container and component diagrams. If Channels, update 08 section 1. My recommendation is PowerSync for reads on both clients, Channels reserved for out-of-band notifications, because it means one read path to test rather than two.

### 1.3 The RBAC matrix contradicts what the OSH proposal promised

- **Document 02, section 2.5** (already sent to Mr. Wellington): "OSH staff can manage assembly points, warden assignments, report recipients and system settings." Section 4: OSH officers "manage settings and recipients."
- **Document 10, section 1** (RBAC): OSH Officer is **No** for "Manage assembly points, zones, areas" and **view only** for "Change system settings."
- **Document 11, section 2.8**: the settings screen is described as "most likely to be touched by someone without a technical background," which implies OSH, not a system administrator.

**Recommendation:** since 02 is the commitment OSH has in hand, revise 10 to match it: OSH Officer gets Yes for managing assembly points, zones and areas, and Yes for changing settings. Keep users, roles, roster import and the audit log as Administrator-only.

### 1.4 The escalation process gives OSH a permission the RBAC matrix does not

**Document 09, section 4** has "OSH manually marks as excused, with note." **Document 10, section 1** has no row granting OSH Officer any status-marking action; "Conduct roll call" is Warden-only.

**Recommendation:** add a row "Override a person's status (mark present/absent/excused with note)" with Yes for OSH Officer and System Administrator, or change 09 section 4 so OSH asks the zone warden to mark the person. The first is the better operational answer; an OSH officer who has just phoned someone should not need to find a warden to record it.

### 1.5 Monorepo versus two repositories

**Document 03, section 2** specifies a single monorepo (`apps/api`, `apps/client`, `packages/`, `docs/`). **Document 12** and the WSL2/Windows setup you have actually done put the Phoenix backend in `/home/malch/salvorion` and the Flutter client in `C:\Users\malch\salvorion`, as two separate directories, and 12's README task explicitly says the client is "not inside this repository."

**Recommendation:** record the two-repository split as the decision, update 03 section 2 accordingly, and decide where `docs/` lives. Simplest: the backend repository carries `docs/` (it is the one you have open in WSL, and it is where every prompt will run). Name them `salvorion-api` and `salvorion-client` in the READMEs so the split is obvious to anyone who finds one without the other.

---

## 2. Gaps that will surface as bugs or missing features

### 2.1 `Activation.close_changeset/2` does not actually enforce "must be active to close"

In the Ecto package, `close_changeset` uses `validate_inclusion(:status, ["active"])`. Ecto's `validate_inclusion` only runs when the field is present in the changeset's *changes*, and `status` is not cast in that changeset, so the check never executes. An activation in `closed` or `scheduled` state could be closed again. The state diagram in 08 section 5 and 07 section 5 both promise this guard.

**Fix:** replace the `validate_inclusion` line with an explicit check on the struct: if `activation.status != "active"`, `add_error(changeset, :status, "activation must be active to close")`.

### 2.2 No schema support for the contradiction flag

**Document 08, section 3** ("flag contradiction record"), **11 section 1.5** (a "Flagged/contradictions" group on the roll-call screen), and **FR-ROLL-05** all require the system to record and surface a contradiction. Neither the ERD (06) nor the Ecto package has anywhere to store it: `PersonStatus` has `status` and `source_event_id` only.

**Fix:** add `contradicting_event_id` (nullable FK to `accountability_events`) and `contradiction_resolved_at` (nullable timestamp) to `person_statuses`, in both 06 and the migration. The roll-call screen's "confirm" action then sets `contradiction_resolved_at`.

### 2.3 No transition to the `reported` state

**08 section 4** ends with "Mark activation status reported" and **08 section 5** draws `closed --> reported`. The Ecto `Activation` module has only `start_changeset` and `close_changeset`. There is also no `schedule_changeset`, so the `scheduled` state in the diagram is unreachable in code.

**Fix:** add `mark_reported_changeset/1` (closed to reported) and, if you want to keep `scheduled` in Release 1, `schedule_changeset/2`; otherwise remove `scheduled` from the state diagram and the status list until Release 2.

### 2.4 The "one active activation per zone" constraint promised in 06 does not exist and cannot be a simple index

**06 section 3** promises "a partial unique index ensuring only one activation can be active per zone." The `create_activations` migration has no such index, and it cannot be written as one: zones are in the `activation_zones` join table, and a campus-wide activation has no rows there at all.

**Fix:** remove the constraint claim from 06 and state that FR-ACT-05 is enforced in the Activations context inside a transaction (check for overlapping active activations before insert). It is priority S, so this is not blocking.

### 2.5 Device revocation has no field to act on

**10 section 4** says a lost device's access is revoked "by disabling that device record." The `Device` schema and migration have no `active`, `revoked_at` or equivalent field.

**Fix:** add `revoked_at` (nullable timestamp) to `devices`; the auth plug rejects tokens whose device is revoked.

### 2.6 The offline-login grace period is required but has no setting

**FR-USR-04** and **10 section 4** both say the grace period is configurable. **03 section 5** and the `Setting` module documentation list `student_accountability_rule`, `visitor_retention_days` and `id_barcode_parser` only.

**Fix:** add `offline_login_grace_hours` (or similar) to the documented setting keys in 03 section 5 and `settings/setting.ex`.

### 2.7 PowerSync's prerequisites are missing from Prompt 1

**Document 12, Task 3** provisions PowerSync but does not tell Claude Code that PowerSync's Postgres source requires `wal_level = logical` (Postgres must be started with that flag), a replication role, and a publication. Without these, the container will start but never replicate, and you will not find out until Stage C. PowerSync also needs a storage backend for its sync buckets; the prompt should say which one so Claude Code does not silently add a MongoDB container.

**Fix:** add to Task 3: run Postgres with `-c wal_level=logical`; create a `powersync` replication user and a `powersync` publication in an init script; configure PowerSync's bucket storage (check PowerSync's current self-hosting docs for whether Postgres storage is supported in the version you pull; if not, add MongoDB and say so explicitly).

### 2.8 Guardian's default signing scheme will not satisfy PowerSync's JWKS requirement

**04 section 1** and **10 section 4** say PowerSync authenticates against a JWKS endpoint Phoenix exposes. Guardian defaults to a symmetric HS512 secret, which cannot be published as a JWKS. This is not a contradiction, but it is a hidden requirement that will bite in the auth prompt.

**Fix:** note in 10 section 4 and in the auth prompt (Stage A item 5) that Guardian must be configured with an asymmetric key (RS256 or ES256) and that Phoenix must expose `/.well-known/jwks.json`.

### 2.9 Prompt 1 should pass `--binary-id`

Every table in the Ecto package uses UUID primary keys. `mix phx.new` without `--binary-id` configures future generators for integer keys, so anything Claude Code later generates with `mix phx.gen.*` will not match. Add `--binary-id` to the Task 1 command in 12. Also reword Task 1's first bullet: "using `mix phx.new salvorion --umbrella` is NOT needed" is ambiguous enough that an agent could read it either way.

### 2.10 FR-SIGN-06 describes behaviour the event model forbids

**FR-SIGN-06:** a duplicate scan "shall update the existing record's timestamp only." The event model (03 section 2.1, 06 section 2, and the `AccountabilityEvent` module's own documentation) is append-only: records are never updated. A second scan of the same person is a new event; a *retried* submission of the same event is deduplicated by `client_uuid`. The SRS wording conflates the two.

**Fix:** reword FR-SIGN-06 as: "A retried submission of the same accountability event (same client identifier) shall not create a duplicate record. A second, distinct scan of a person already present shall not change their status."

### 2.11 Minor code issues in the Ecto package

- `20260908000001_enable_extensions.exs` passes an empty string as the `down` for each `execute`. Use `"DROP EXTENSION IF EXISTS ..."` instead so a rollback does not attempt an empty statement.
- The ERD (06) gives `DEVICE` a `registered_at` column; the migration uses `inserted_at` from `timestamps()`. Pick one (`inserted_at` is the Ecto convention) and align the ERD.
- The ERD omits `updated_at` on `USER`; the migration has it. Cosmetic.

---

## 3. Stale content from the NestJS to Phoenix switch

**Document 04, section 4** says everything in 03 outside the stack table still applies "adjusted only for the backend language." That understates how much of 03 is now wrong:

| Location in 03 | Stale content | Should say |
|---|---|---|
| Section 2, monorepo layout | `apps/api/ NestJS backend`, `packages/openapi/` | Two repositories (see 1.5); Phoenix API; OpenAPI generated by `open_api_spex` |
| Section 2, backend modules | NestJS module list including `signins`, `rollcalls`, `visitors`, `dashboard`, `notifications`, `sync` | The nine Phoenix contexts in 07 section 3: accounts, organisation, locations, roster, activations, accountability, reporting, audit, settings |
| Section 2, client layers | "presentation (Riverpod providers ...)" | Bloc |
| Section 3, AccountabilityEvent | status includes `unaccounted` | `present | absent | excused` only; `unaccounted` is a PersonStatus value (06 and the Ecto package are correct) |
| Section 3, User roles | `SystemAdmin, OSHOfficer, Warden, ReportViewer` | see section 4 below |
| Section 5, ID barcode parser | maps to `Person.idNumber` | `Person.id_number` |
| Section 5, student accountability rule | lists `residence_based` | Not in FR-ROS-05 or in `setting.ex`; either add it to both as a Release 2 value or remove it here |
| Section 7, Stage A items 1 to 3 | "Docker Compose (PostgreSQL, Redis)", "NestJS app scaffold", "Prisma schema" | Postgres, PowerSync, Gotenberg; Phoenix scaffold; Ecto migrations (already written) |
| Section 7, Stage C item 16 | "Riverpod" | Bloc |
| Section 8 | "Riverpod, GoRouter and an offline sync scaffold" | Bloc, GoRouter, PowerSync SDK; kido-luci's template with Firebase and `rev_sync` removed |
| Section 9 | "ERD and Prisma schema" | Ecto |

Elsewhere:

- **01 section 5**, Design deliverables: "Prisma schema" should be "Ecto schema."
- **04 section 1**, Report generation: still says Puppeteer "run as an Elixir Port or a small internal service." 07, 08 and 12 all use Gotenberg as a separate container, which was the decision. Update 04 to name Gotenberg.
- **10, status line**: "before Stage B (auth module)". Auth is Stage A item 5 in 03. 10 section 7 has it right.
- **12, "How to use this"**: says `~/dev/`; the folder you created is `~/salvorion`.

---

## 4. Naming drift

### 4.1 The fourth role has four names and is conflated with a non-user entity

| Where | Name used |
|---|---|
| 05 FR-USR-01, 05 section 2.3, 10 RBAC, 07 context diagram | Report Recipient (as a *role* / user class) |
| 03 section 3 | ReportViewer |
| Ecto `User.role` | `report_viewer` |
| Ecto `ReportRecipient` schema, 06 ERD | ReportRecipient (an email-only record, explicitly *not* a user) |
| 07 section 1 | "report recipients never log in" |
| 02 section 4, 05 section 2.3 | "may be given read-only dashboard access" |

Two different things share one name. **Recommendation:** the *record* is `ReportRecipient` (someone who receives email; no login). The optional read-only *login role* is `report_viewer`, called "Report Viewer" in prose. Update FR-USR-01 and the RBAC column header to "Report Viewer," and change 07 section 1 to "report recipients do not need a login."

### 4.2 Role names across documents

Canonical set, to be used everywhere from now on:

| Prose | `User.role` value |
|---|---|
| System Administrator | `admin` |
| OSH Officer | `osh_officer` |
| Safety Warden | `warden` |
| Report Viewer | `report_viewer` |

03 section 3 should be updated to this table.

### 4.3 Student accountability default

- 01 section 9: "contextual (students expected on campus at the time)"
- 02 question 2: timetable-based if data available, otherwise signed-in-only
- 05 Appendix A: "Signed-in-only default; timetable-based deferred to Release 2"

Not contradictory, but three phrasings of one decision. Since timetable data will not exist in Release 1, the charter's assumption should say "signed-in-only in Release 1, timetable-based in Release 2, subject to OSH confirmation."

### 4.4 `UNISS (UNISS)` in 01 section 6

A find-and-replace artefact. Should read `UNISS (IT Services)`.

---

## 5. Minor

- **05 section 7** traceability covers only six objectives; FR-VIS, FR-ROS, FR-LOC, FR-USR and FR-AUD trace to nothing. Acceptable for a draft, but O6 should also list NFR-OFF-03 (the 60-second resync target from the charter's O2/O6).
- **09 section 5** has "OSH notified no recipients are configured." No notification mechanism exists in any document. Either specify it (a dashboard banner is enough) or remove the word "notified."
- **11 section 1.2** contains a garbled sentence ("A reason field is not required by the SRS but a free-text note field is (FR-ROLL-03 ...)"). FR-ROLL-03 is roll call, not manual sign-in. `AccountabilityEvent.note` exists for every event kind, so the intended statement is: "An optional note field is available; the audit trail (FR-SIGN-04) is automatic."
- **11 section 3** adds an "Activity" screen to mobile navigation that no functional requirement covers. Either add an S-priority FR ("The mobile app shall show a warden their own recent actions and their sync state") or drop the screen.
- **09 section 1** has "OSH Officer or designated staff starts activation." The RBAC matrix grants this only to OSH Officer; "designated staff" would need that role. Fine as written if that is understood.
- **07 section 3** places "PowerSync Sync Rules" inside the Phoenix API boundary. They are a configuration file for the PowerSync service, not Phoenix code. Move the component outside the Phoenix boundary (or into the PowerSync container) to avoid a future reader looking for it in `lib/`.
- **12, verification checklist** refers to "item 5 above" as Claude Code's self-report; item 5 is the tree view. Say "the VERIFICATION section" instead.

---

## 6. Suggested order of fixes

1. Decide 1.1, 1.2, 1.3, 1.4, 1.5 (five decisions; my recommendations are stated in each).
2. Apply the Ecto package fixes in 2.1 to 2.6 and 2.11 (code changes; can be done in one pass and re-zipped).
3. Update 12 per 2.7, 2.8, 2.9 and the path in section 3, since it is the next thing you will run.
4. Apply the SRS rewording in 2.10 and 4.1.
5. Rewrite 03 sections 2, 3, 5, 7, 8, 9 per section 3, or mark 03 as superseded and fold the surviving content (domain model, feature scope, NFR targets, development sequence) into a new Document 03a written for Phoenix and PowerSync.
6. Mechanical text fixes: 01 (UNISS, Prisma, section 9 wording), 04 (Gotenberg), 10 (status line, role column), 11 (1.2 sentence), 09 (notification wording).

---

## 7. Resolution record (11 September 2026)

All findings were applied as recommended. Decisions taken:

| Finding | Decision |
|---|---|
| 1.1 Write path | PowerSync's upload queue is the offline outbox; the connector's `uploadData` POSTs to Phoenix with `client_uuid`. Drift is client-only data. |
| 1.2 Dashboard read path | Both clients read through PowerSync. Phoenix Channels are reserved for out-of-band pushes. |
| 1.3 RBAC vs proposal | OSH Officer may manage assembly points, zones, areas and settings, matching Document 02. |
| 1.4 Escalation permission | New FR-ROLL-07: OSH Officer and System Administrator may override a person's status with a mandatory note. |
| 1.5 Repositories | Two repositories: `salvorion-api` (WSL2, carries `docs/`) and `salvorion-client` (Windows). |

Changes made:

- **Ecto package** (re-zipped): `close_changeset` now guards on the struct's status; `schedule_changeset/2` and `mark_reported_changeset/1` added; `person_statuses` gained `contradicting_event_id`, `contradiction_resolved_at` and a partial index on open contradictions; `devices` gained `revoked_at`; `offline_login_grace_hours` documented as a setting key; the extensions migration has a real `down`. Every table and its schema were re-checked for balanced syntax after editing.
- **12** (Prompt 1): path corrected to `~/salvorion`; `phx.new` command rewritten with `--binary-id`, `--no-live` and in-place generation; Postgres started with `wal_level=logical` plus a replication role and publication; PowerSync storage backend to be taken from its documentation, not guessed; a `docs/DECISIONS.md` note for the asymmetric Guardian key and the upload-queue decision; verification now checks `SHOW wal_level`.
- **01**: `UNISS (IT Services)`; Ecto instead of Prisma in deliverables; student accountability assumption reworded.
- **03**: section 1 marked superseded; sections 2, 3, 5, 6, 7, 8, 9 rewritten for Phoenix, PowerSync, Bloc, Gotenberg and the two-repository layout; `residence_based` removed; `id_number` corrected; offline grace setting added.
- **04**: Gotenberg named as the renderer; section 4's Stage C item 17 now records the upload-queue decision.
- **05**: FR-SIGN-06 reworded; FR-USR-01 uses Report Viewer and separates recipients from users; FR-USR-05 (Activity screen) and FR-ROLL-07 (status override) added; section 5.4 and the traceability table updated; user classes split into Report Recipient (no login) and Report Viewer.
- **06**: `PERSON_STATUS`, `DEVICE` and `USER` entities updated; the impossible partial unique index replaced by an application-layer statement; new partial index documented.
- **07**: report-recipient wording; container relationships redrawn for the PowerSync read path and upload queue; sync rules moved into the PowerSync boundary; JWKS endpoint added; client components gained the connector.
- **08**: online and offline sign-in sequences redrawn around PowerSync's upload queue; contradiction sequence names the real column; report sequence and state diagram name the changesets.
- **09**: "notified" replaced with a dashboard banner; escalation references FR-ROLL-07.
- **10**: status line; Report Viewer column; OSH Officer permissions widened per 1.3; override row added; asymmetric key and JWKS requirement; `revoked_at`; grace-period setting.
- **11**: manual-entry sentence repaired; Activity screen references FR-USR-05; settings screen attributed to OSH Officers; confirm action names the column it sets.

Not changed: **02** (already sent to OSH; nothing in it was found to be wrong, and it is the document the RBAC was aligned to).
