# Sequence, State and Deployment Diagrams

**Document:** 08 of the project record
**Version:** 0.2 (Draft; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** For review. Completes the diagram set promised at the end of Document 07.

All diagrams are Mermaid, rendering in VS Code (Mermaid Preview extension), GitHub, and any Mermaid-compatible viewer.

---

## 1. Sequence diagram: sign-in, online

The straightforward path, when the warden's device has connectivity at the moment of the scan.

```mermaid
sequenceDiagram
    actor W as Warden
    participant App as Mobile App (Flutter)
    participant API as Phoenix API
    participant DB as PostgreSQL
    participant PS as PowerSync
    participant Web as Web Dashboard

    W->>App: Scans ID card
    App->>App: mobile_scanner decodes barcode
    App->>App: Generate client_uuid, capture client_timestamp
    App->>App: Record event locally; PowerSync upload queue drains immediately (online)
    App->>API: Connector POSTs /accountability_events (client_uuid, person lookup key, activation_id, ...)
    API->>DB: Resolve person by id_number
    API->>DB: Insert AccountabilityEvent (kind: scanned, server_timestamp = now)
    API->>DB: Upsert PersonStatus (activation_id, person_id, status: present, source_event_id)
    API-->>App: 201 Created
    App-->>W: Confirmation beep + green check
    DB-->>PS: Logical replication picks up the change
    PS-->>Web: Reactive query updates dashboard
    Web-->>Web: Participation rate and unaccounted list re-render
```

**What to notice:** the confirmation to the warden (the beep and green check) comes back from the direct API call, not from PowerSync. The dashboard update is a separate, slightly slower path through replication. This is intentional: the person standing at the scanner needs instant feedback regardless of how fast the dashboard happens to refresh.

---

## 2. Sequence diagram: sign-in, offline

The path that matters most for this system, since assembly points frequently have no connectivity.

```mermaid
sequenceDiagram
    actor W as Warden
    participant App as Mobile App (Flutter)
    participant PS as PowerSync SDK (local SQLite + upload queue)
    participant API as Phoenix API
    participant DB as PostgreSQL

    W->>App: Scans ID card
    App->>App: Generate client_uuid, capture client_timestamp
    App->>PS: Record event in local SQLite; PowerSync places it in the upload queue
    App-->>W: Confirmation beep + green check (optimistic, from local state)
    Note over App,PS: Device has no connectivity.<br/>Event sits in PowerSync's upload queue.
    W->>App: Continues scanning; more events queue locally
    Note over PS: Connectivity returns; PowerSync resumes uploading
    loop For each queued write, in order, via the connector's uploadData
        PS->>API: POST /accountability_events (same client_uuid as originally generated)
        API->>DB: Insert if client_uuid not already present (idempotent)
        API-->>PS: 201 Created (or 200 if already existed)
        PS->>PS: Remove write from upload queue
    end
    Note over PS: Server-derived PersonStatus replicates back down, replacing the optimistic local state
```

**What to notice, and why it matters:** the outbox is PowerSync's own upload queue, not a hand-built table (Document 04, section 4; Document 13, finding 1.1). The warden's confirmation happens the instant they scan, entirely from local state, before any network call is attempted. This is what "fully operable offline" (NFR-OFF-01) actually means in practice: the UI never waits on the network to tell the warden their scan worked. The `client_uuid` generated at the moment of the scan, not at the moment of syncing, is what makes the eventual sync idempotent (FR-SIGN-06): if the app crashes mid-sync and retries, or if a request succeeds but the response is lost, resubmitting the same `client_uuid` simply confirms the row already exists rather than duplicating it.

---

## 3. Sequence diagram: roll call contradiction

The one genuinely tricky data path in the system (FR-ROLL-05).

```mermaid
sequenceDiagram
    actor S as Someone
    actor Wa as Warden A (at scanner)
    actor Wb as Warden B (doing roll call)
    participant API as Phoenix API
    participant DB as PostgreSQL

    S->>Wa: Presents ID card at assembly point
    Wa->>API: Sign-in event (kind: scanned, status: present)
    API->>DB: Insert event; upsert PersonStatus = present (source: scanned)

    Note over Wb: Warden B has not yet seen this scan sync to their device
    Wb->>API: Roll-call event (kind: roll_call, status: absent)
    API->>DB: Insert event (always inserted; events are never rejected)
    API->>DB: Check existing PersonStatus for this person/activation
    DB-->>API: Existing status is "present", sourced from a scanned event
    API->>API: Apply contradiction rule: scanned outranks roll_call
    API->>DB: PersonStatus remains "present"; set contradicting_event_id = the roll-call event
    API-->>Wb: Response includes the contradiction flag
    Note over Wb: PersonStatus (with contradicting_event_id) also replicates to Warden B via PowerSync
    Wb->>Wb: App highlights the person as "flagged: scan says present"
```

**What to notice:** the flag is a real column, `person_statuses.contradicting_event_id`, cleared by setting `contradiction_resolved_at` when the warden confirms (FR-ROLL-05; Document 06). Both events are always stored. Nothing is ever rejected or silently dropped, since the event log is the audit trail and every action a warden takes must be recoverable later. What changes is only the *derived* `PersonStatus`, and the losing event's kind is surfaced back to the warden as a flag rather than hidden, so a human resolves the ambiguity rather than the system quietly picking a side without anyone noticing.

---

## 4. Sequence diagram: report generation and delivery

```mermaid
sequenceDiagram
    actor O as OSH Officer
    participant Web as Web Dashboard
    participant API as Phoenix API
    participant Activations as Activations Context
    participant Oban as Oban (job queue)
    participant PDF as PDF Render Service
    participant SES as Amazon SES
    actor R as Report Recipient

    O->>Web: Clicks "Close Activation"
    Web->>API: PATCH /activations/:id (close)
    API->>Activations: close_changeset/2
    Activations->>Activations: Validate status was "active"
    Activations-->>API: Activation now "closed"
    API->>Oban: Enqueue GenerateReportJob(activation_id)
    API-->>Web: 200 OK, activation closed

    Oban->>Oban: Picks up GenerateReportJob
    Oban->>API: Compile report data (participation rates, unaccounted list, manual sign-ins)
    Oban->>PDF: POST /render (HTML report template + data)
    PDF-->>Oban: PDF bytes
    Oban->>Oban: Store ReportRun (pdf_path, status: generated)
    Oban->>Oban: Enqueue DeliverReportJob per active ReportRecipient

    loop For each active recipient
        Oban->>SES: Send email with PDF attached
        SES-->>Oban: Delivery accepted / failed
        Oban->>Oban: Update ReportDelivery status
    end

    SES-->>R: Report email arrives
    Oban->>Activations: mark_reported_changeset/1 (closed -> reported)
```

**What to notice:** report generation is entirely decoupled from the request that closes the activation. The OSH Officer's click returns immediately once the activation is marked closed; everything from PDF rendering onward happens in the background via Oban, which is what keeps the heavier PDF-rendering work (see the Technology Stack document's note on Puppeteer/Gotenberg's memory footprint) from ever blocking a user-facing request.

---

## 5. State diagram: Activation lifecycle

```mermaid
stateDiagram-v2
    [*] --> scheduled: Officer schedules an activation (schedule_changeset/2; optional)
    scheduled --> active: Officer starts it (activation_type locked from this point on)
    [*] --> active: Officer starts one directly, with no scheduling step
    active --> closed: Officer closes it (close_changeset/2; rejected unless status is active)
    closed --> reported: Report generated and all deliveries attempted (mark_reported_changeset/1)
    reported --> [*]

    note right of active
        activation_type (drill | real) cannot change.
        Only one activation may be active per zone
        at a time (FR-ACT-05).
    end note

    note right of closed
        No new AccountabilityEvents accepted
        for this activation from this point on.
    end note
```

**What to notice:** `scheduled` is genuinely optional in Release 1, most activations (especially real emergencies) will go straight from nothing to `active`. The state machine still models it because a drill is often planned in advance, and having the state available costs nothing now but would be a schema change later if omitted.

---

## 6. Deployment diagram

Where each container actually runs, for the initial release, per the constraint of keeping hosting costs modest.

```mermaid
C4Deployment
    title Salvorion — Initial Deployment

    Deployment_Node(cloud, "Cloud Host", "e.g. Fly.io / Render / DigitalOcean droplet") {
        Deployment_Node(app_vm, "Application VM/Container Group") {
            Container(phoenix, "Phoenix API", "Elixir release")
            Container(powersync, "PowerSync Service", "Docker image")
            Container(pdf, "PDF Render Service", "Gotenberg, Docker image")
        }
        Deployment_Node(db_vm, "Managed PostgreSQL", "Provider-managed, with automated backups") {
            ContainerDb(postgres, "PostgreSQL", "Primary database")
        }
    }

    Deployment_Node(dev_machine, "Developer Machine", "Malik's laptop, Windows + WSL2") {
        Deployment_Node(wsl, "WSL2 (Ubuntu)") {
            Container(dev_phoenix, "Phoenix (dev mode)")
            Container(dev_docker, "Docker Compose", "Local Postgres, PowerSync, Gotenberg for development")
        }
        Deployment_Node(windows, "Windows (native)") {
            Container(dev_flutter, "Flutter (dev mode)", "Android emulator + Chrome for web preview")
        }
    }

    Deployment_Node(android, "Warden's Phone", "Android or iOS") {
        Container(mobile_app, "Salvorion Mobile App", "Installed APK/IPA")
    }

    Deployment_Node(browser, "OSH Officer's Computer") {
        Container(web_app, "Salvorion Web Dashboard", "Runs in browser")
    }

    System_Ext(ses, "Amazon SES")

    Rel(mobile_app, phoenix, "HTTPS", "Production")
    Rel(mobile_app, powersync, "Sync protocol", "Production")
    Rel(web_app, phoenix, "HTTPS + WebSocket", "Production")
    Rel(phoenix, postgres, "Ecto/TCP")
    Rel(powersync, postgres, "Logical replication")
    Rel(phoenix, ses, "API")

    Rel(dev_phoenix, dev_docker, "Connects to local Postgres/PowerSync/Gotenberg")
    Rel(dev_flutter, dev_phoenix, "HTTP to localhost, via WSL2's forwarded ports", "Development only")
```

**What to notice about the development leg specifically, since this is what you're setting up right now:** WSL2 forwards `localhost` ports to Windows automatically, so once your Phoenix dev server is running inside WSL2 on, say, port 4000, your natively-installed Flutter app on the Windows side can reach it at `http://localhost:4000` without any extra networking configuration. That's one of the more pleasant WSL2 defaults and it's why the split-environment setup (backend in WSL2, Flutter native) doesn't cause the friction it might sound like it would.

---

## 7. What remains after this document

Per the original SDLC sequence: business process models for the drill-activation and escalation workflows (BPMN-style, closer to an operational flowchart than a technical diagram), wireframes for the key screens, and the security design document (RBAC matrix, data classification). These can wait until Erlang and Elixir finish installing, or be tackled in the same documentation pass if you'd rather keep working on paper while your battery holds out.
