# Salvorion: Final Technology Stack

**Document:** 04 of the project record
**Version:** 1.1 (Confirmed; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** Confirmed. This document supersedes the stack table in section 1 of the Technical Foundation document (03). Everything else in that document (architecture pattern, domain model, feature scope, development sequence) still applies, with the adjustments noted in section 4 below.

---

## 1. The stack

| Layer | Choice | Reason (short form) |
|-------|--------|----------------------|
| Backend language and framework | **Elixir / Phoenix**, current stable | Runs on the BEAM VM, built for massive concurrency and fault isolation. Every warden's device can hold a live connection during an activation without one bad event taking the rest down. This is the best fit for a real-time, safety-critical system, more so than any TypeScript or .NET option. |
| Database access | **Ecto** | Phoenix's standard data layer. Changesets give declarative validation and casting; query composition is clean and type-safe within Elixir's conventions. Not a downgrade from Prisma or Drizzle, a respected tool in its own right. |
| Real-time / pub-sub | **Phoenix Channels and PubSub** (built in) | Native to the framework. Handles WebSocket fan-out to the dashboard and to warden devices without an external message broker. Benchmarked to millions of concurrent connections on a single node, far beyond anything NCU will need, which means comfortable headroom rather than a system operating near its limits. |
| Background jobs | **Oban** | Postgres-backed job queue for the Elixir ecosystem. Runs report generation, email delivery, roster refresh and the visitor-data purge job durably, using the database you already run. No separate queue service. |
| Database | **PostgreSQL** (v16 or later) | Reliable, transactional, strong JSON support, and the replication source for the sync layer below. |
| Client-server sync | **PowerSync** | Connects to Postgres via logical replication and keeps an embedded SQLite database on each client in sync, with an official Flutter SDK built for local-first, real-time apps. Removes most of the hand-built offline outbox and snapshot-and-cursor design; you define sync rules (who can see which rows) and your own API remains where writes are validated before landing in Postgres. Self-hosted via its published Docker image. |
| Mobile and web client | **Flutter** (Dart), current stable | One codebase for Android, iOS and web. The warden app is the safety-critical, camera-driven part of the system, and Flutter is strongest exactly there. The web dashboard will read as an application rather than a website, which suits this project's intent. |
| Client state management | **Bloc** | Explicit event-in, state-out model. Mirrors the event-sourced design of the backend (an action becomes an event, an event becomes a new state) and enforces more structure than lighter alternatives, which suits a long-lived, audited system over minimising boilerplate. Consumes Drift's reactive streams as naturally as any alternative would. |
| Client local database | **Drift** (SQLite) | Typed SQL, reactive queries, and SQLCipher-backed encryption at rest. Works underneath or alongside PowerSync's local store for any client-only data that doesn't need to sync. |
| Client routing | **GoRouter** | The Flutter team's own router. Identical behaviour on mobile and web, handles deep links. |
| Barcode / QR scanning | **mobile_scanner** | Camera-based, actively maintained, covers the 1D symbologies likely on an ID card (Code 128, Code 39) as well as QR. |
| Report generation | **Gotenberg** (a containerised Chromium/Puppeteer HTML-to-PDF service), run as its own container and called by Oban over HTTP | Full visual control, and the report format is the deliverable most likely to change after OSH reviews it. An HTML template previewed in a browser is far easier to iterate on than a typesetting DSL. Isolating the renderer in its own container keeps its large image and per-render memory spike away from the Phoenix API process. |
| Email | **Amazon SES** | Cheaper than Postmark, appropriate for internal transactional notifications rather than customer-facing mail, abstracted behind a mailer module so the provider can change later without touching business logic. |
| Authentication | **JWT access tokens with refresh tokens**, via **Guardian** (Elixir), argon2 password hashing | Stateless, works offline via a cached token, and matches the JWT and JWKS endpoint PowerSync itself expects for authenticating sync connections. Session-based auth was ruled out because it doesn't survive offline use, which this system requires. |
| API contract | **OpenAPI 3.1**, generated from Phoenix route and schema definitions; Dart client generated from it | Keeps the Flutter client's API calls in sync with the backend automatically. |
| Containers | **Docker** and **Docker Compose** | Identical local and production environments; PowerSync's service also ships as a Docker image, so the whole backend stack composes together. |
| Hosting (initial) | A container host such as Fly.io, Render or a DigitalOcean droplet, with managed PostgreSQL | Low cost, easy to move, decided in the feasibility note. Fly.io has particularly good support for Elixir clustering if that is ever needed. |
| CI | **GitHub Actions** | Lint, test and build on every push; build Flutter artefacts on tags. |
| Testing | **ExUnit** (backend, Phoenix's built-in test framework); Flutter `test` and `integration_test` (client); k6 (load testing) | Standard tooling for each layer. |

---

## 2. What was ruled out, and why

| Layer | Rejected option | Reason |
|-------|-----------------|--------|
| Client | React / React Native | Would need react-native-web to reach the browser, which is worse than Flutter at both mobile and web. Only competitive for a web-only client, which this isn't. |
| Client | Native (Kotlin + Swift) plus a separate web framework | Three codebases for one developer; not viable. |
| Client | Kotlin Multiplatform / Compose Multiplatform | Strong on Android, but web support is still immature and the scanning and offline ecosystem is smaller. |
| Client | .NET MAUI | No web target; would need a separate Blazor project. |
| Client | Capacitor (Angular, Vue or Svelte wrapped as a mobile app) | Camera and background sync depend on plugins; offline SQLite is bolted on rather than native; noticeably weaker under fast repeated scanning. |
| Client | Progressive Web App only | iOS limits on camera access, background sync and storage eviction are too risky for an emergency tool. |
| Dashboard | Separate SvelteKit web app, embedded in or alongside the Flutter app | Embedding it would mean a WebView, losing Flutter's native performance and state management for that screen while gaining none of SvelteKit's actual advantage. A separate dashboard project would mean maintaining two front-end codebases. The Flutter web dashboard, built from an existing admin template, is expected to be good enough on its own. |
| State management | Riverpod | A legitimate alternative with less boilerplate, but Bloc's explicit structure was preferred once boilerplate was deprioritised in favour of enforced discipline and closer alignment with the event-sourced backend. |
| State management | Provider, GetX | Provider is a lighter, older version of the same idea as Riverpod; GetX's global, implicit state works against the auditability this system needs. |
| Local database | sqflite (raw) | Drift sits on top of it and provides typed queries and migrations for free. |
| Local database | Isar | Fast, but maintenance has been inconsistent; not something to stake an emergency tool on. |
| Local database | Hive | Key-value only; no relational queries or real migrations. |
| Local database | ObjectBox | Has built-in sync, but that sync is commercial and proprietary. |
| Sync | Hand-built outbox and snapshot/cursor engine | Still the documented fallback (see section 4), but PowerSync covers the same need with a maintained SDK and less code to own. |
| Backend | NestJS (TypeScript) with Prisma or Drizzle | A strong, safe choice, and the more conservative one given your existing TypeScript fluency. Set aside in favour of Phoenix once real-time concurrency at scale was weighed more heavily, and because you're comfortable using AI assistance to bridge the Elixir learning curve. |
| Backend | ASP.NET Core with SignalR and Entity Framework | Genuinely competitive: mature tooling, excellent ORM, real-time via SignalR, and the strongest option if NCU turns out to run on Microsoft 365 and Entra ID becomes central. Set aside because Phoenix has more headroom and more graceful failure under load, which matters more for an emergency tool than for most software. |
| Backend | Go, plain Fastify/Hono | Fast and reliable, but no compelling advantage over Phoenix for this domain, and a less rich ecosystem for the PDF and email side of the system. |
| Backend, real-time and jobs | Redis with BullMQ | Redundant once Phoenix is chosen. Phoenix PubSub handles real-time fan-out and Oban handles background jobs, both natively and both backed by Postgres, so no separate service needs to be run, backed up or monitored. |
| ORM | Prisma, Drizzle | Both are TypeScript ORMs and only apply on the NestJS branch. Ecto is Phoenix's equivalent and is not a lesser tool, simply the one that goes with this backend. |
| Email | Postmark | Better deliverability reputation, but at a higher cost that isn't justified for internal, non-customer-facing notifications. |

---

## 3. The full picture in one paragraph

The backend is an Elixir and Phoenix application using Ecto against PostgreSQL, with Oban running background jobs and Phoenix's built-in Channels and PubSub handling real-time updates, all without any additional infrastructure beyond Postgres itself. PowerSync sits between Postgres and the client, replicating data down to an embedded SQLite database on each device and handling reconnection and sync automatically, while writes still flow through the Phoenix API for validation. The client is a single Flutter codebase for Android, iOS and web, using Bloc for state management, Drift for any client-local data outside the synced store, GoRouter for navigation, and mobile_scanner for barcode and QR capture. Reports are rendered from HTML templates to PDF by the Gotenberg service and delivered by Amazon SES. Authentication is JWT-based via Guardian, satisfying both the system's own needs and PowerSync's authentication requirements. Everything runs in Docker, tested with ExUnit and Flutter's test tooling, deployed to a low-cost container host.

---

## 4. Adjustments this makes to the Technical Foundation document (03)

- **Section 1** (stack table) is superseded by section 1 of this document.
- **Section 2.1** (offline-first and sync design): the hand-rolled outbox, idempotent event ingest and snapshot pull remain the conceptual model for how writes become events, but the transport and local-storage mechanics are now provided by PowerSync rather than built from scratch. The append-only `AccountabilityEvent` design, and the contradiction rule (a scan outranks a roll-call absence), are unchanged.
- **Section 7, Stage B, item 12** ("Sync module: snapshot endpoint, batched event ingest, per-device cursors") is replaced by: configure PowerSync sync rules against the Ecto schema, and expose the write endpoints PowerSync's client calls through.
- **Section 7, Stage C, item 17** ("Drift schema mirroring the server's sync shape; outbox; sync worker; connectivity handling") is replaced by: integrate the PowerSync Flutter SDK; use PowerSync's upload queue as the offline outbox, with a backend connector whose `uploadData` POSTs each queued write to the Phoenix API carrying the client-generated `client_uuid`; define local Drift tables only for client-only data; and implement Bloc classes that consume PowerSync's reactive queries. Both the mobile app and the web dashboard read through PowerSync; Phoenix Channels are reserved for out-of-band pushes (for example the contradiction flag), not for row replication.
- All other sections of document 03 (domain model, feature scope by release, non-functional targets, and the general development sequence) stand as written, adjusted only for the backend language moving from TypeScript to Elixir where module and file structure are discussed in future prompts.

---

## 5. Confirmation

This stack is confirmed. The next deliverables are the SRS, the ERD (translated into an Ecto schema rather than Prisma), the C4 architecture diagrams reflecting Phoenix and PowerSync, and the Stage A development prompts, beginning with the Phoenix project scaffold and Docker Compose setup (Postgres, PowerSync service).
