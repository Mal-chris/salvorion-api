# Software Architecture Document: C4 Diagrams

**Document:** 07 of the project record
**Version:** 0.2 (Draft; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** For review before Stage A development begins

This document uses the C4 model: Context, Container, Component, and (where useful) Code. Each level zooms in on the previous one. All diagrams are Mermaid, so they render in VS Code (with the Mermaid Preview extension), GitHub, and most documentation tooling.

---

## 1. Level 1: System Context

Who and what interacts with Salvorion, without any internal detail.

```mermaid
C4Context
    title Salvorion — System Context

    Person(warden, "Safety Warden", "Conducts roll calls and sign-ins at an assembly point")
    Person(osh, "OSH Officer", "Starts and monitors activations, manages settings")
    Person(admin, "System Administrator", "Manages users, locations, roster imports")
    Person(recipient, "Report Recipient", "e.g. HR, Dean, SRM — receives reports by email")

    System(salvorion, "Salvorion", "Emergency assembly accountability and compliance tracking")

    System_Ext(roster_source, "NCU Roster Source", "Staff/student data: file export today, direct system later")
    System_Ext(email, "Amazon SES", "Delivers report emails")
    System_Ext(powersync_cloud, "PowerSync Service", "Replicates data to offline clients")

    Rel(warden, salvorion, "Scans IDs, registers visitors, conducts roll calls", "Mobile app, often offline")
    Rel(osh, salvorion, "Starts/closes activations, views dashboard", "Web app")
    Rel(admin, salvorion, "Configures the system", "Web app")
    Rel(salvorion, recipient, "Sends activation report", "Email")
    Rel(salvorion, roster_source, "Imports roster data", "File / export / direct connection")
    Rel(salvorion, email, "Sends via", "SMTP/API")
    Rel(salvorion, powersync_cloud, "Replicates changes to/from", "Logical replication + sync protocol")
```

**Reading this diagram:** Salvorion is the one box in the middle. Everything else is either a person or a system Salvorion depends on but does not control. Notice that report recipients do not need a login; they receive email. Where OSH wants someone to see the dashboard as well, that person is given the separate read-only `report_viewer` role (FR-USR-01). Keeping the two apart keeps the list of people who need credentials small.

---

## 2. Level 2: Container Diagram

The deployable units inside Salvorion and how they talk to each other.

```mermaid
C4Container
    title Salvorion — Container Diagram

    Person(warden, "Safety Warden")
    Person(osh, "OSH Officer / Admin")
    Person(recipient, "Report Recipient")

    System_Boundary(salvorion, "Salvorion") {
        Container(flutter_mobile, "Warden Mobile App", "Flutter (Android/iOS)", "Sign-in, visitor registration, roll calls. Works offline via local SQLite.")
        Container(flutter_web, "Web Dashboard & Admin", "Flutter Web", "Live dashboard, administration, reporting UI")
        Container(phoenix_api, "Phoenix API", "Elixir / Phoenix", "Business logic, validation, auth, activation state machine, WebSocket channels")
        Container(powersync, "PowerSync Service", "Self-hosted (Docker)", "Replicates Postgres to client-embedded SQLite; enforces per-user sync rules")
        ContainerDb(postgres, "PostgreSQL", "Relational database", "Single source of truth for all data")
        Container(pdf_service, "PDF Render Service", "Gotenberg (containerised Chromium)", "Renders the HTML report template to PDF, isolated from the main API")
        Container(oban, "Background Jobs", "Oban (runs inside Phoenix, Postgres-backed)", "Report generation trigger, email delivery, roster refresh, visitor purge")
    }

    System_Ext(roster_source, "NCU Roster Source")
    System_Ext(ses, "Amazon SES")

    Rel(warden, flutter_mobile, "Uses")
    Rel(osh, flutter_web, "Uses")

    Rel(flutter_mobile, powersync, "Reads via; queues writes in its upload queue", "PowerSync protocol, offline-tolerant")
    Rel(flutter_web, powersync, "Reads live data via", "PowerSync protocol")
    Rel(flutter_mobile, phoenix_api, "Connector uploads queued writes to; receives out-of-band pushes from", "HTTPS/JSON + Phoenix Channels")
    Rel(flutter_web, phoenix_api, "Sends activation start/close and admin writes to", "HTTPS/JSON + Phoenix Channels")

    Rel(powersync, postgres, "Reads via logical replication")
    Rel(phoenix_api, postgres, "Reads/writes via Ecto")
    Rel(phoenix_api, oban, "Enqueues jobs into")
    Rel(oban, postgres, "Job queue table in")
    Rel(oban, pdf_service, "Requests PDF render from", "HTTP")
    Rel(oban, ses, "Sends report email via", "API")
    Rel(ses, recipient, "Delivers report to")
    Rel(phoenix_api, roster_source, "Imports from", "File upload / scheduled pull")
```

**Reading this diagram, and why it looks the way it does:**

- **Two client containers, one Flutter codebase.** The Warden Mobile App and the Web Dashboard are drawn separately because they serve different users with different UI, but they are built and shipped from the same Flutter project (see the Final Technology Stack, section 3, for why a separate SvelteKit dashboard was ruled out).
- **Reads and writes take different paths, and both clients read the same way.** This is the single most important structural decision in the whole system. *Reads* (the roster, current statuses, the dashboard feed) come from PowerSync's replicated local SQLite database on every client, mobile and web alike, so the dashboard and the warden's list are driven by the same replication stream. *Writes* (a sign-in, a roll-call mark) are recorded locally and placed in PowerSync's upload queue, which is the offline outbox; the client's PowerSync connector uploads each queued write to the Phoenix API, where it is validated, turned into an `AccountabilityEvent` row, and committed. The client-generated `client_uuid` travels with the write so a retry after a dropped connection is idempotent. Phoenix Channels are used only for out-of-band pushes that are not row replication, such as the contradiction flag returned to a warden.
- **The PDF renderer is its own container**, not code running inside Phoenix, specifically because of the memory and image-size cost discussed earlier. Oban calls it over HTTP the same way it would call any external service, so a spike in report-rendering memory never touches the process serving live API traffic.
- **Oban and the job queue live inside Postgres**, not in a separate Redis container. This is what "dropping Redis" (Technology Stack document, section 2) looks like at the container level: one fewer box to deploy, back up and monitor.

---

## 3. Level 3: Component Diagram — Phoenix API

Zooming into the one container with the most internal structure.

```mermaid
C4Component
    title Salvorion — Phoenix API Component Diagram

    Container_Boundary(phoenix_api, "Phoenix API") {
        Component(auth_ctx, "Accounts", "Elixir context", "Users, roles, warden assignments, devices, JWT issuance via Guardian")
        Component(org_ctx, "Organisation", "Elixir context", "Faculties, departments, programmes")
        Component(loc_ctx, "Locations", "Elixir context", "Assembly points, zones, areas, department-area mapping")
        Component(roster_ctx, "Roster", "Elixir context", "Person records; RosterProvider behaviour and implementations")
        Component(activation_ctx, "Activations", "Elixir context", "Activation lifecycle and state machine")
        Component(accountability_ctx, "Accountability", "Elixir context", "AccountabilityEvent ingest, PersonStatus derivation, ExpectedPresence computation, contradiction rule")
        Component(reporting_ctx, "Reporting", "Elixir context", "Report generation orchestration, recipients, delivery tracking")
        Component(audit_ctx, "Audit", "Elixir context", "Immutable audit log writer, queried by admins")
        Component(settings_ctx, "Settings", "Elixir context", "Key/value configuration, e.g. student accountability rule")
        Component(channels, "Phoenix Channels", "Real-time layer", "Out-of-band pushes to clients, e.g. contradiction flags; not used for row replication")
        Component(jwks, "JWKS endpoint", "Phoenix", "Publishes the public signing key PowerSync uses to verify client tokens")
        Component(web_router, "Router & Controllers", "Phoenix", "HTTP endpoints, request validation, OpenAPI generation")
    }

    ContainerDb(postgres, "PostgreSQL")
    Container_Boundary(powersync_boundary, "PowerSync Service") {
        Component(sync_rules, "Sync Rules", "PowerSync configuration file", "Defines which rows each authenticated user's device may read")
    }
    Container(oban, "Oban")

    Rel(web_router, auth_ctx, "Authenticates via")
    Rel(web_router, accountability_ctx, "Routes sign-in/roll-call writes to")
    Rel(web_router, activation_ctx, "Routes activation start/close to")
    Rel(web_router, roster_ctx, "Routes roster import to")

    Rel(accountability_ctx, activation_ctx, "Reads active/expected state from")
    Rel(accountability_ctx, roster_ctx, "Resolves person records via")
    Rel(accountability_ctx, channels, "Broadcasts PersonStatus updates via")
    Rel(activation_ctx, reporting_ctx, "Triggers report generation on close via", "Oban job")
    Rel(reporting_ctx, oban, "Enqueues render + email jobs in")
    Rel(roster_ctx, settings_ctx, "Reads student_accountability_rule from")

    Rel(auth_ctx, postgres, "Persists via Ecto")
    Rel(org_ctx, postgres, "Persists via Ecto")
    Rel(loc_ctx, postgres, "Persists via Ecto")
    Rel(roster_ctx, postgres, "Persists via Ecto")
    Rel(activation_ctx, postgres, "Persists via Ecto")
    Rel(accountability_ctx, postgres, "Persists via Ecto")
    Rel(reporting_ctx, postgres, "Persists via Ecto")
    Rel(audit_ctx, postgres, "Persists via Ecto")
    Rel(settings_ctx, postgres, "Persists via Ecto")

    Rel(sync_rules, postgres, "Defines row visibility over")
    Rel(sync_rules, jwks, "Verifies client tokens against")
```

**Reading this diagram:** The sync rules are drawn inside the PowerSync service, not the Phoenix API, because they are a configuration file PowerSync reads, not Elixir code; do not look for them under `lib/`. Each remaining box under "Phoenix API" corresponds directly to a `lib/salvorion/<context>` folder, which is exactly the folder structure already generated in the Ecto schema package (document 06). This is deliberate: the architecture diagram and the actual code layout are the same shape, so there is no translation step between "what the diagram says" and "what file I open." The `Audit` context has no incoming write relationships drawn from other contexts individually only because every context calls it the same way (fire-and-forget on every mutation); that pattern will be enforced with a shared `Salvorion.Audit.record/1` helper rather than drawn as ten separate arrows.

---

## 4. Level 3: Component Diagram — Flutter Client

```mermaid
C4Component
    title Salvorion — Flutter Client Component Diagram

    Container_Boundary(flutter_app, "Flutter App (mobile + web)") {
        Component(presentation, "Presentation", "Bloc + Widgets", "Screens for scanning, roll calls, dashboard, admin; one Bloc per feature, consuming streams")
        Component(domain, "Domain", "Plain Dart", "Entities and use-case classes, framework-agnostic")
        Component(repo_layer, "Repositories", "Dart", "One repository per domain concept (Activations, People, Events); hides whether data comes from PowerSync or the API")
        Component(powersync_sdk, "PowerSync SDK", "Flutter package", "Local SQLite mirror, reactive queries, upload queue (the offline outbox), reconnection handling")
        Component(connector, "PowerSync Connector", "Dart", "uploadData: POSTs each queued write to the Phoenix API with its client_uuid; fetchCredentials: supplies the JWT")
        Component(api_client, "API Client", "Dio + generated from OpenAPI", "Used by the connector for queued writes, and directly for non-queued calls: activation start/close, admin actions")
        Component(scanner, "Scanner", "mobile_scanner", "Camera-based barcode/QR capture")
        Component(local_only_db, "Local-Only Store", "Drift", "Client-only data that never syncs: draft form state, device settings")
        Component(auth_module, "Auth", "Guardian-issued JWT, flutter_secure_storage", "Token storage and refresh; also the credential PowerSync uses to authenticate")
    }

    Container(phoenix_api, "Phoenix API")
    Container(powersync, "PowerSync Service")

    Rel(presentation, domain, "Invokes use cases in")
    Rel(domain, repo_layer, "Calls")
    Rel(repo_layer, powersync_sdk, "Reads from; records accountability writes into")
    Rel(powersync_sdk, connector, "Drains upload queue through")
    Rel(connector, api_client, "Uploads via")
    Rel(repo_layer, api_client, "Sends non-queued writes through")
    Rel(presentation, scanner, "Receives scan events from")
    Rel(scanner, repo_layer, "Passes scanned payload to")
    Rel(presentation, local_only_db, "Reads/writes client-only state via")
    Rel(api_client, auth_module, "Attaches token from")
    Rel(powersync_sdk, auth_module, "Authenticates using")

    Rel(powersync_sdk, powersync, "Syncs with", "Offline-tolerant")
    Rel(api_client, phoenix_api, "Calls", "HTTPS, queued locally when offline")
```

**Reading this diagram:** The key line is `repo_layer` sitting between the Bloc-driven presentation layer and what it talks to underneath: PowerSync for reads and for queued accountability writes (which the connector uploads to the API), and the API client directly for writes that should not be queued, such as starting an activation. No Bloc ever calls PowerSync or Dio directly; it always goes through a repository. That is what keeps the read/write split from Level 2 from leaking into every screen's code, and it is what makes the client testable, since a repository is trivial to fake in a Bloc test.

---

## 5. What comes next

- A sequence diagram for the sign-in flow (scan to dashboard update, both online and offline)
- A sequence diagram for the report generation flow (activation close to email delivered)
- A state diagram for the Activation lifecycle (scheduled → active → closed → reported, with the "cannot change type" and "cannot close except from active" rules from the Ecto changesets made visual)
- A deployment diagram showing where each container actually runs (single host to start, per the Technology Stack document)

These will follow once you confirm this document, or can be produced alongside the first Stage A prompts if you'd rather start typing now and treat the diagrams as documentation-in-parallel rather than a gate.
