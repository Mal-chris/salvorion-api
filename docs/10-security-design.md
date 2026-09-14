# Security Design

**Document:** 10 of the project record
**Version:** 0.2 (Draft; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** For review before Stage A item 5 (the auth and audit contexts) is built

This document translates the security-related requirements in the SRS (NFR-SEC-01 to NFR-SEC-04, NFR-PRIV-01, NFR-PRIV-02) into concrete rules: who can do what, how data is classified, and how it is protected in transit, at rest, and in logs.

---

## 1. Role-based access control (RBAC) matrix

Four roles exist, matching FR-USR-01. Permissions are additive; a higher-privilege role is not assumed to include a lower one's permissions automatically; each is listed explicitly so the Phoenix authorization policy (implemented as Guardian-issued claims checked by a plug on every route) has no ambiguous cases.

| Action | System Administrator | OSH Officer | Safety Warden | Report Viewer |
|---|:---:|:---:|:---:|:---:|
| Start an activation | | Yes | | |
| Close an activation | | Yes | | |
| View live dashboard | Yes | Yes | Own zone/area only | Yes (read-only) |
| View activation history | Yes | Yes | No | Yes (read-only) |
| Perform sign-in (scan/manual) | Yes | Yes | Yes | No |
| Register a visitor | Yes | Yes | Yes | No |
| Conduct roll call | | | Own assigned zone/area only | |
| Override a person's status with a mandatory note (FR-ROLL-07) | Yes | Yes | No | No |
| View unaccounted list (all zones) | Yes | Yes | No (own zone/area only) | No |
| Manage assembly points, zones, areas | Yes | Yes | No | No |
| Manage departments, faculties, programmes | Yes | No | No | No |
| Manage warden assignments | Yes | Yes | No | No |
| Import roster data | Yes | No | No | No |
| Manage report recipients | Yes | Yes | No | No |
| Manually regenerate/resend a report | Yes | Yes | No | No |
| Manage users and roles | Yes | No | No | No |
| View audit log | Yes | No | No | No |
| Change system settings (e.g. accountability rule) | Yes | Yes | No | No |
| Receive reports by email | Only if also listed as a ReportRecipient | Only if also listed as a ReportRecipient | No | Only if also listed as a ReportRecipient |

**Notes:**
- A Safety Warden's dashboard visibility is scoped to their own `WardenAssignment` rows. This is enforced both at the API layer (every accountability query filters by the requesting user's assignments) and at the PowerSync sync-rules layer (a warden's device only ever replicates rows for zones/areas they're assigned to), so a compromised or modified client cannot simply ask for more than it's shown.
- Report recipients (the people who receive the emailed report) are `ReportRecipient` records, not users, and have no login. The `report_viewer` role is the separate, optional read-only login OSH may grant to some of them (OSH Proposal, section 4; FR-USR-01). The two are deliberately distinct so that adding someone to the email list never creates an account.
- OSH Officer manages assembly points, zones, areas and system settings because the proposal OSH has in hand (Document 02, sections 2.5 and 4) commits to that. Users, roles, roster import and the audit log stay Administrator-only.
- System Administrator and OSH Officer are deliberately kept distinct even though one person may hold both roles in practice, because the department managing physical safety response (OSH) and the person managing user accounts and roster imports (System Administrator, likely you, during Release 1) should not be assumed to be the same person once the system has a real administrative team.

---

## 2. Data classification

| Category | Examples | Classification | Handling rule |
|---|---|---|---|
| Directory information | Staff/student name, department, faculty, ID number | Internal | Visible to any authenticated user role in the course of their duties; never exposed unauthenticated |
| Contact information | Email, phone (staff, students, visitors) | Internal | Same as directory information; visitor contact details are also subject to the retention rule below |
| Accountability records | Sign-in events, roll-call marks, statuses | Internal, permanent | Retained indefinitely as compliance history (per the OSH Proposal, section 6, item 10); never deleted, only ever appended to |
| Visitor personal details | Name, host, contact number | Internal, time-limited | Purged automatically after the configured retention period (default 90 days; FR-VIS-04); the purge itself is audited |
| Authentication credentials | Password hashes, JWT signing keys | Restricted | Password hashes via argon2, never logged, never included in any export or report; signing keys held as environment secrets, never committed to source control |
| Audit log | Every create/update/delete action | Restricted | Readable only by System Administrators; never editable or deletable by any role (NFR: immutability) |
| Roster import artifacts | Uploaded CSV/Excel files | Internal, transient | Retained only long enough to support troubleshooting a failed import, then deleted; the `RosterImport` record (counts, errors) is retained, the underlying file is not |
| Generated reports (PDF) | Participation rates, unaccounted lists | Internal | Retained in activation history alongside the activation itself; access restricted to Administrator and OSH Officer roles, **plus the Report Viewer role** (`report_viewer` may list and download an activation's generated reports — this is the whole purpose of that read-only login, Document 02 section 4 — but not manage recipients or trigger a manual regenerate, which stay Administrator/OSH Officer only), plus whichever named recipients received it by email |

**No category in this system reaches "Restricted — special category" under the Jamaican Data Protection Act** (no health data, no financial data, no biometric data is collected; ID card scanning reads an identifier, not a biometric template). This keeps the compliance burden proportionate to what OSH actually needs, and is worth confirming explicitly with OSH before the pilot, since it affects what disclosures, if any, are owed to staff, students and visitors about what the system records.

---

## 3. Encryption

| Layer | Requirement | Mechanism |
|---|---|---|
| Data in transit | All client-server traffic encrypted | TLS 1.2 or later, enforced at the load balancer/reverse proxy in front of Phoenix; HTTP requests redirected to HTTPS |
| Data in transit, sync | PowerSync's replication and client sync traffic | TLS, per PowerSync's own deployment defaults |
| Data at rest, server | Database contents | Managed PostgreSQL's disk-level encryption (provider default; to be confirmed against whichever host is chosen in the feasibility note) |
| Data at rest, client | Local SQLite store on warden devices | SQLCipher-backed encryption via Drift/PowerSync's encrypted mode, so a lost or stolen phone does not expose cached roster and accountability data |
| Credentials in transit and storage | Passwords | Never transmitted or stored in plaintext; argon2 hashing server-side; the client never retains a plaintext password after login, only the resulting JWT |
| Secrets | Database credentials, JWT signing keys, SES API keys | Environment variables injected at deploy time, never committed to the repository; local development uses a `.env` file excluded via `.gitignore` |

---

## 4. Authentication and session handling

- JWT access tokens are short-lived (proposed 15 minutes) with a longer-lived refresh token (proposed 30 days), issued and verified via Guardian. Guardian must be configured with an asymmetric signing key (RS256 or ES256) rather than its default HS512 secret, because PowerSync verifies client tokens against a JWKS endpoint (`/.well-known/jwks.json`) that Phoenix exposes; a symmetric secret cannot be published as a JWKS.
- The mobile app caches the current valid token to permit continued use during a network outage (FR-USR-04), for a configurable grace period (`Setting: offline_login_grace_hours`); once that grace period expires without successful re-verification, the app requires re-authentication before further accountability-affecting actions.
- Device registration (the `Device` schema) associates a device with a user, so a lost or decommissioned device's access can be revoked by setting `devices.revoked_at`; the auth plug rejects tokens whose device is revoked, without disabling the user's account.
- PowerSync authenticates using the same JWT, via a JWKS endpoint Phoenix exposes, so there is exactly one identity system in the whole architecture, not two to keep in sync.

---

## 5. Audit logging

- Every create, update and delete action across every context writes an `AuditLog` row (FR-AUD-01), via a shared helper function called from each context rather than duplicated per module, so the practice cannot be accidentally skipped when a new feature is added later.
- Audit rows are never updated or deleted by any application code path; there is deliberately no `update_changeset` or delete function defined on the `AuditLog` schema (FR-AUD-02).
- System-initiated actions (the visitor purge job, an automated report retry) still produce an audit row, attributed to a null actor rather than silently going unrecorded, so "who or what changed this" is always answerable.
- Audit logs are viewable and filterable only by System Administrators (FR-AUD-03).

---

## 6. Privacy-specific controls

- **Visitor retention.** A scheduled Oban job runs daily, finds `Person` records of type `visitor` whose `visitor_expires_at` has passed, and deletes their personal fields (name, host, contact), retaining only an anonymised placeholder so historical `AccountabilityEvent` rows referencing them remain intact for compliance history without exposing who the visitor was. This job's own execution is audited (NFR-PRIV-01).
- **No PII in logs.** Application-level logging (Phoenix's own request logs, error tracking) is configured to exclude request bodies for endpoints that carry personal data, and structured log messages reference records by ID rather than by name or contact detail (NFR-PRIV-02).
- **Roster data minimisation.** The roster integration layer (Document 03, section 2.2) requests only the fields the system actually uses (name, ID number, department/programme, contact detail for account-holding roles) rather than importing a full HR or student-system record wholesale, even if a wider export is offered.

---

## 7. What this means for the upcoming Stage A prompts

- The Accounts context's auth module (Stage A, item 5) must implement the RBAC matrix in section 1 as an authorization plug checked on every route, not as scattered per-controller checks.
- The Audit context (also Stage A, item 5) must exist and be wired in before any other context starts writing data, since retrofitting audit coverage onto existing write paths is more error-prone than building it in from the first migration.
- The visitor purge job (Stage B, item 10, per the Technical Foundation's development sequence) implements section 6 directly.
- TLS, secrets management and encrypted local storage are deployment and configuration concerns (Stage D) but are noted here so they are never treated as an afterthought once a working system exists.
