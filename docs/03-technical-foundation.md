# Salvorion: Technical Foundation

**Document:** 03 of the project record
**Version:** 0.2 (Draft; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** Confirmed, with section 1 superseded by Document 04. Sections 2, 3, 5, 7, 8 and 9 were rewritten on 11 September to reflect Phoenix, PowerSync and Bloc; the NestJS/Prisma/Riverpod originals are recorded in the project history only. Revised again 14 September 2026 (Document 27): "sync rules" corrected to Sync Streams throughout, §2.2's roster provider names updated to their actual module names, §7.1 added mapping this document's item numbers to the prompt numbers that actually built them, and §5's `id_barcode_parser`/`offline_login_grace_hours` rows corrected to state plainly that both are reserved keys, not yet consulted by any code path (finding 7.4).

This document fixes the decisions that everything downstream depends on: the technology stack, the architecture, the domain model, the feature scope by release, and the order in which development will proceed. It is written so that development can begin on synthetic data while OSH feedback is pending, without needing to redesign later.

---

## 1. Technology stack

> **Superseded.** The table below was the initial proposal (NestJS, Prisma, Redis, Riverpod). The confirmed stack is Elixir/Phoenix, Ecto, Oban, PowerSync, Flutter with Bloc, Drift, GoRouter, Gotenberg and Amazon SES, as recorded in **Document 04**. It is kept here only so the reasoning trail is visible.

| Layer | Choice | Why |
|-------|--------|-----|
| Mobile and web client | **Flutter** (Dart), current stable | One codebase for Android, iOS and web. Mature barcode scanning, strong offline database support, strict typing, fast rendering. Not React. |
| Client state management | **Riverpod** | Compile-safe, testable, no global mutable state, well suited to offline-first data flows. |
| Client local database | **Drift** (SQLite) | Typed SQL, reactive queries, migrations, and it is the standard choice for offline-first Flutter. |
| Client routing | **GoRouter** | Declarative, deep-link capable, works identically on mobile and web. |
| Barcode / QR scanning | **mobile_scanner** | Actively maintained, supports the common 1D and 2D symbologies, camera-based, works on both platforms. |
| Backend framework | **NestJS** (TypeScript), current stable | Modular, opinionated, built-in validation and guards, first-class WebSocket gateways, and it fits your existing Prisma and PostgreSQL experience. |
| ORM and migrations | **Prisma** | Your existing stack; typed client, migration history, good PostgreSQL support. |
| Database | **PostgreSQL** (v16 or later) | Reliable, transactional, strong JSON support for audit payloads, row-level security available if needed later. |
| Cache, queues, pub/sub | **Redis** with **BullMQ** | Background jobs (report generation, email, roster refresh) and real-time fan-out to dashboard clients. |
| Real-time | **WebSockets** via NestJS gateway (Socket.IO) | Live dashboard updates when a sign-in or roll call entry syncs. |
| Report generation | **Puppeteer** rendering an HTML template to PDF | Full control over layout; the same template can be previewed in the browser. |
| Email | **Postmark** or **Amazon SES** (abstracted behind a mailer interface) | Reliable transactional delivery; the interface lets you switch providers without touching business logic. |
| Authentication | JWT access tokens (short-lived) with refresh tokens; argon2 password hashing; optional **Microsoft Entra ID** SSO later | Standard, stateless, works offline (cached token) and can be extended to NCU's identity provider if they use Microsoft 365. |
| API contract | **OpenAPI 3.1** generated from NestJS decorators; Dart client generated from it | Keeps client and server in sync automatically. |
| Containers | **Docker** and **Docker Compose** | Identical local and production environments. |
| Hosting (initial) | Any container host: Fly.io, Render, Railway or a DigitalOcean droplet; managed PostgreSQL | Low cost, easy to move. Decided in the feasibility note. |
| CI | **GitHub Actions** | Lint, test, build on every push; build Flutter artefacts on tags. |
| Testing | Jest and Supertest (backend); Flutter test and integration_test (client); k6 (load) | Standard tooling for each layer. |

**Rejected alternatives, for the record.** React and Next.js (excluded by your constraint). Angular (viable but adds a second front-end stack alongside Flutter for mobile). SvelteKit (excellent for the web dashboard but same drawback). Kotlin Multiplatform (immature for web). Go backend (fast and reliable, but you would lose Prisma and the NestJS module system for no gain at this scale). Supabase or Firebase (convenient, but they push business logic to the client and complicate an adapter-based roster integration).

---

## 2. Architecture overview

Two repositories, not a monorepo. The backend lives in WSL2 and the Flutter client lives natively on Windows (Document 08, section 6), so they are separate Git repositories that communicate only over the network.

```
salvorion-api/        Elixir / Phoenix backend (WSL2: /home/malch/salvorion)
  lib/salvorion/        Ecto contexts (one folder per context, below)
  lib/salvorion_web/    Router, controllers, channels, JWKS endpoint
  priv/repo/migrations/ Ecto migrations (Document 06 package)
  priv/report_templates/ HTML/CSS templates for PDF reports
  docs/                 Project record (all numbered documents)
  docker-compose.yml    Postgres, PowerSync, Gotenberg for local development

salvorion-client/     Flutter app, mobile + web (Windows: C:\Users\malch\salvorion)
  packages/features/    One package per feature (kido-luci layout)
  packages/core/        Domain, repositories, PowerSync connector, API client
```

**Backend contexts** (one `lib/salvorion/<context>` folder each, matching Document 07 section 3): `accounts` (users, roles, warden assignments, devices, Guardian), `organisation` (faculties, departments, programmes), `locations` (assembly points, zones, areas, department-area mapping), `roster` (people, `RosterProvider` behaviour and implementations, imports), `activations` (lifecycle and state machine), `accountability` (event ingest, `PersonStatus` derivation, `ExpectedPresence`, contradiction rule), `reporting` (report runs, recipients, deliveries), `audit`, `settings`. Real-time pushes go through Phoenix Channels; background work through Oban.

**Client layers** (Clean Architecture): `data` (PowerSync SDK and connector, Drift for client-only tables, generated API client), `domain` (entities and use cases), `presentation` (Bloc classes, screens, widgets). Web and mobile share everything; a small `platform` layer handles camera access and storage differences.

### 2.1 Offline-first and sync design (summary; full design comes in the design phase)

- Every accountability record the client creates (sign-in, visitor registration, roll-call entry) is an **append-only event** with a client-generated UUID, a device ID, a client timestamp and a monotonic sequence number.
- Events are recorded locally first, then the UI updates from local state. The **outbox is PowerSync's upload queue**: the client's PowerSync connector uploads each queued event to the Phoenix API in order whenever connectivity exists (Document 04, section 4; Document 08, section 2).
- The server accepts events **idempotently** (the UUID is the key), so retries after a dropped connection never duplicate.
- Because records are events rather than mutable rows, most "conflicts" disappear: two wardens marking the same person present is two events, and the server derives the person's current status from the latest event by server-received time, with the full history kept for audit.
- The one real conflict, contradictory statuses for the same person (present from a scan, absent from a roll call), is resolved by a deterministic rule: a physical scan outranks a roll-call absence, and the dashboard flags the contradiction for the warden to confirm.
- The client's local copy of the roster, locations, active activation and current statuses is kept current by **PowerSync replication** under per-user **Sync Streams** (PowerSync's current mechanism, confirmed against its own documentation in Prompt 10 — not the legacy bucket-based "Sync Rules" format this document originally assumed before that prompt ran; see `docs/DECISIONS.md`, "PowerSync sync config (Prompt 10): Sync Streams, not Sync Rules"), so a warden joining late still has the full picture; no hand-built snapshot endpoint is needed.

### 2.2 Roster integration layer

A `Salvorion.Roster.Provider` behaviour (implemented as an Elixir behaviour, not an interface in the OOP sense — this section originally named it before implementation settled the actual module names) with, per Release 1, two real implementations plus two Release-2 placeholders, selected by configuration:

| Provider | Use |
|----------|-----|
| `Salvorion.Roster.Providers.FileImport` | CSV upload through the admin UI (Prompt 4). Interim path and the one actually built and used first; Excel is not implemented (docs/DECISIONS.md/Document 25, finding 3.5). |
| `Salvorion.Roster.Providers.Synthetic` | Generates a realistic campus for development, testing, the drill simulator and demonstrations (Prompt 4). |
| `ScheduledExportProvider` (Release 2, not yet built) | Picks up a file UNISS drops on SFTP or shared storage on a schedule; module name still proposed, not fixed, since nothing has implemented it yet. |
| `DirectDatabaseProvider` (Release 2, not yet built) | Read-only connection to a UNISS-provided view. Last resort, only with their agreement; module name likewise still proposed. |

Every provider implements the same `fetch_records/1` callback and produces the same `Salvorion.Roster.Provider.raw_record()` shape (this section originally called it `RosterRecord`, before implementation settled on a plain typed map rather than a struct), so the rest of the system never knows where the data came from.

---

## 3. Domain model (entities)

Organisational hierarchy (for compliance reporting):

- **Faculty**, **Department**, **Programme**. Departments belong to a faculty or to an administrative division; programmes belong to a faculty.

Physical hierarchy (for roll calls):

- **AssemblyPoint** (name, description, optional coordinates), **Zone** (number, assembly point), **Area** (name, zone, optional building and floor). Areas are the entries in the OSH guide; a building can have several areas across zones.

People:

- **Person** (type: staff, student, visitor; ID number; name; contact; primary department or programme; usual area). Staff and students come from the roster; visitors are created at registration.
- **Person ↔ Department** is many-to-many (Steel Building units, joint appointments).
- **User** (login identity) linked optionally to a Person. **Roles** (`User.role` value in brackets): System Administrator (`admin`), OSH Officer (`osh_officer`), Safety Warden (`warden`), Report Viewer (`report_viewer`). Report *recipients* who only receive email are `ReportRecipient` records, not users.
- **WardenAssignment** (user, zone or area, effective dates).

Activations:

- **Activation** (type: drill or real; status: scheduled, active, closed, reported; started/closed by; times; scope: whole campus or selected zones).
- **AccountabilityEvent** (append-only: activation, person, kind: scanned, manual, roll-call, visitor-registered; status: present, absent, excused; recorded by; device; client and server timestamps; assembly point; note). `unaccounted` is never an event status; it is the derived `PersonStatus` of an expected person with no event.
- **PersonStatus** (derived view per activation: current status, source event, and the contradicting event plus resolution timestamp when a scan and a roll-call mark disagree).
- **ExpectedPresence** (per activation: which people are expected, computed by the accountability rule in effect; see section 5).

Reporting and administration:

- **ReportRun** (activation, generated at, PDF path, delivery status), **ReportRecipient** (email, name, role, active).
- **RosterImport** (provider, started, completed, counts, errors).
- **Device** (registered client device, platform, last sync, revoked-at).
- **AuditLog** (actor, action, entity, before/after, timestamp). Immutable.
- **Setting** (key/value for configurable rules, including the student accountability rule and visitor retention period).

---

## 4. Feature scope by release

### Release 1 (core accountability and reporting)

**Activations.** Start (choose drill or real, choose scope), monitor, close. Type locked after start.
**Sign-in.** Scan ID barcode; manual entry by ID number; name search; each manual entry audited. Works offline.
**Visitors.** Register (name, host, contact, area visiting); issue temporary QR; visitor counted; personal details purged after the configured retention period.
**Roll calls.** Warden sees expected people for their zone/area with live status; marks absent, excused, present; adds a note; works offline; contradictions flagged.
**Dashboard (web).** Live per-department and per-faculty participation; per-zone counts; unaccounted list with filters; drill vs real banner; activation timeline; history of past activations.
**Reports.** Auto-generated PDF on close; emailed to configured recipients; downloadable from history; manual regenerate.
**Administration.** Manage assembly points, zones, areas; departments and faculties; warden assignments; users and roles; report recipients; settings; roster import via file with validation preview.
**Roster.** File import provider; synthetic provider; import history.
**Security and audit.** RBAC; audit log on every write; device registration.
**Synthetic data and drill simulator.** Generate a campus; simulate a drill with N wardens and M sign-ins per minute including offline periods, for load and sync testing.

### Release 2 (after the pilot)

Scheduled export and direct database roster providers; timetable-based expected presence for students; Microsoft Entra SSO; push notifications to wardens on activation start; escalation workflow for unaccounted people; multi-campus support; trend analytics across activations; NFC as a secondary identifier.

### Explicitly out of scope (from the charter)

ID card redesign; mass notification; fire panel integration; physical access control; timetable management.

---

## 5. Handling the decisions still pending from OSH

Nothing that OSH has not yet decided is hardcoded. Each is a configurable setting or a data record so the answer can change without a release.

| Pending decision | How the design absorbs it |
|------------------|---------------------------|
| Report recipients | `ReportRecipient` records managed in the admin UI |
| Student accountability rule | `Setting: student_accountability_rule` with values `all_enrolled`, `signed_in_only` (Release 1 default), `timetable_expected` (Release 2). `ExpectedPresence` is computed by the rule in effect at activation start. |
| Student grouping | Faculty and programme both stored; dashboard grouping is a selector |
| Warden devices | Any device; a shared-tablet mode allows one device to act for multiple wardens with per-entry attribution |
| ID barcode format | `Setting: id_barcode_parser` — **reserved key** (Document 25, finding 7.4): the key is defined and documented, but no code path consults it yet, since scan-to-`Person.id_number` resolution in Release 1 has exactly one, hardcoded behaviour ("payload is the ID number," `Roster.get_person_by_id_number/1`); the setting exists so a future, non-trivial parser (e.g. extracting an ID number from a structured QR payload) can be selected without a code change, once one is actually built |
| Assembly point mapping | Seed data from the OSH guide, editable in admin |
| Warden list | `WardenAssignment` records, importable |
| Retention | `Setting: visitor_retention_days` (default 90) enforced by a nightly Oban job |
| Offline login grace period | `Setting: offline_login_grace_hours` (FR-USR-04) — **reserved key** (Document 25, finding 7.4): documented as part of the design, not yet consulted by any code path, since the mobile app itself (Stage C) hasn't been built; see Document 10 §4 for the intended behaviour once it is |
| Report format | HTML template in `priv/report_templates`, rendered by Gotenberg, editable without code changes to the API |
| Zones 7, 11, 12, 13 populations | Areas seeded; whether their people are in the roster is a roster question, not a system change |

---

## 6. Non-functional requirements (targets for the SRS)

- **Offline:** all warden and sign-in functions available with zero connectivity; PowerSync upload queue must hold at least 10,000 events per device.
- **Sync:** upload queue drained within 60 seconds of reconnection under normal conditions; no data loss on app kill or device restart.
- **Latency:** dashboard reflects a synced event within 10 seconds.
- **Scale:** a single activation with 50 concurrent wardens and 5,000 events in 15 minutes without degradation.
- **Availability:** 99.5% for the API outside planned maintenance (the client tolerates API outages by design).
- **Security:** TLS everywhere; argon2 password hashing; JWT expiry 15 minutes with 30-day refresh; RBAC on every endpoint; audit log immutable; local database encrypted at rest on mobile (SQLCipher via Drift).
- **Privacy:** visitor purge job; roster imports logged; no personal data in application logs; data protection review before pilot.
- **Accessibility:** WCAG 2.1 AA for the web dashboard; large touch targets and high-contrast mode for the warden app (it will be used outdoors, in sunlight, under stress).
- **Maintainability:** every module has tests; OpenAPI is the single source of truth for the API; documentation lives in the repo.

---

## 7. Development sequence (the prompt series will follow this order)

Each numbered item becomes one or more VS Code prompts, each self-contained with file paths, acceptance checks and a commit message.

**Stage A: Foundation**
1. Backend repository (`salvorion-api`), Phoenix scaffold (API-only, binary IDs), tooling, Docker Compose (PostgreSQL with logical replication, PowerSync, Gotenberg), CI skeleton (Document 12)
2. Configuration, health check, logging conventions, error handling conventions, Oban setup
3. Ecto migrations and schemas for the full domain model (the Document 06 package), seed runner
4. Synthetic roster provider and the OSH assembly point seed data
5. Accounts context (Guardian with an asymmetric key, JWKS endpoint, refresh tokens, roles, authorisation plug) and Audit context

**Stage B: Core backend**
6. Organisation and locations modules (CRUD, validation)
7. Roster module: `RosterProvider` interface, file import with validation preview, import history
8. Activations module with state machine
9. Sign-in and accountability events: idempotent ingest endpoint, status derivation, contradiction rule
10. Visitors module with QR issuance and retention job
11. Roll-call module and warden assignments
12. PowerSync Sync Streams against the Ecto schema; the write endpoints the client connector uploads through
13. Dashboard aggregation queries and Phoenix Channels for out-of-band pushes
14. Reporting context: HTML template, Gotenberg render job, recipients, SES mailer, delivery tracking, closed-to-reported transition
15. OpenAPI generation (open_api_spex) and Dart client generation

**Stage C: Client**
16. Client repository (`salvorion-client`) from the kido-luci starter: strip Firebase and `rev_sync`; Bloc, GoRouter, theme (high contrast, large targets), platform layer
17. PowerSync SDK integration: schema, connector (`uploadData`, `fetchCredentials`), upload queue as outbox, Drift for client-only tables, connectivity indicator
18. Auth screens and token lifecycle (including offline login with cached credentials)
19. Activation status and initial sync
20. Scanner screen (barcode, manual entry, name search) with instant local feedback
21. Visitor registration and QR pass
22. Warden roll-call screens
23. Web dashboard screens (live boards, unaccounted list, history)
24. Admin screens (locations, organisation, wardens, users, recipients, settings, roster import)

**Stage D: Quality and release**
25. Drill simulator and load tests
26. Offline and sync failure test suite
27. End-to-end tests, accessibility pass
28. Deployment: Dockerfiles, environment configuration, hosting, backups, runbook
29. Pilot preparation: real roster connection, data protection checklist, warden training materials

### 7.1 Item numbers here versus actual prompt numbers (added per Document 27)

The numbered items above and the actual VS Code prompt numbers referenced throughout `docs/DECISIONS.md` and documents 12–24 have never lined up one-to-one — items were split across two prompts, reordered relative to each other, or folded into a neighbouring prompt with no dedicated item of their own. Document 25's consistency audit found every later document assumes a reader can make this translation unaided; this table is that translation.

| §7 item | What it describes | Actual prompt(s) | Prompt document |
|---|---|---|---|
| Stage A, 1 | Backend repo, Phoenix scaffold, Docker Compose, CI skeleton | Prompt 1 | 12 |
| Stage A, 2 | Configuration, health check, logging/error-handling conventions, Oban setup | No standalone prompt — folded into Prompts 1 and 2 | 12, 14 |
| Stage A, 3 | Ecto migrations and schemas for the full domain model | Prompt 2 | 14 |
| Stage A, 4 | Synthetic roster provider and OSH assembly point seed data | Split: OSH seed data → Prompt 3; synthetic provider → Prompt 4 | 15, 16 |
| Stage A, 5 | Accounts context (Guardian, JWKS, roles, auth plug) and Audit context | Prompt 2 | 14 |
| Stage B, 6 | Organisation and Locations modules | Prompt 3 | 15 |
| Stage B, 7 | Roster module | Prompt 4 | 16 |
| Stage B, 8 | Activations module with state machine | Prompt 5 | 17 |
| Stage B, 9 | Sign-in and accountability events | Prompt 6 | 18 |
| Stage B, 10 | Visitors module | Prompt 8 — built *after* item 11, not before | 20 |
| Stage B, 11 | Roll-call module and warden assignments | Prompt 7 — built *before* item 10, alongside dashboard aggregation (item 13's other half) | 19 |
| Stage B, 12 | PowerSync Sync Streams against the schema; write endpoints | Prompt 10 | 22 |
| Stage B, 13 | Dashboard aggregation queries and Phoenix Channels | Split: dashboard aggregation → Prompt 7 (with item 11); Channels → Prompt 12, built *last*, after Reporting, not before it | 19, 24 |
| Stage B, 14 | Reporting context | Prompt 11 | 23 |
| Stage B, 15 | OpenAPI generation and Dart client generation | Not started as of Stage B's completion (Document 25) | — |
| *(no §7 item at all)* | HTTP routes/controllers consolidating every context built by items 6–11 into `lib/salvorion_web` | Prompt 9 | 21 |

---

## 8. Front-end starting points

Rather than build the client from scratch, the plan is to start from kido-luci's Flutter starter (Bloc, GoRouter, injectable/get_it, package-based Clean Architecture), removing its Firebase integration and its ObjectBox-based `rev_sync` engine and wiring in the PowerSync SDK instead, then port dashboard layouts and components from a Flutter admin template (FlareLine, with the Flutter Responsive Admin Panel as a fallback) and use GetWidget and fl_chart for components and charts. Licences and current buildability against Flutter stable will be confirmed in Stage C, item 16, before anything is adopted.

---

## 9. What is needed to confirm this document

1. Agreement on the stack in section 1.
2. Agreement on the Release 1 / Release 2 split in section 4.
3. Any additions to the domain model in section 3 from your knowledge of NCU.

The SRS (05), ERD and Ecto package (06), C4 diagrams (07) and the remaining design documents (08 to 11) have since been produced from this document and audited for consistency (13). Stage A prompts start with Document 12.
