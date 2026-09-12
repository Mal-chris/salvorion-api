# Software Requirements Specification (SRS)

**Project:** Salvorion — Emergency Assembly Accountability and Compliance Tracking System
**Document:** 05 of the project record
**Version:** 0.2 (Draft; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** For confirmation. Once confirmed, this document is the baseline against which design, development and testing are measured. Changes after baseline go through change control.

This SRS follows the structure of IEEE 830, adapted for a solo-developer, milestone-driven project. It builds on the Project Charter (01), the OSH Proposal (02), the Technical Foundation (03) and the Final Technology Stack (04).

---

## 1. Introduction

### 1.1 Purpose

This document specifies the functional and non-functional requirements for Salvorion. It is written for three audiences: OSH, who will confirm that it reflects what they need; the developer (Malik Christopher), who will build against it; and any future maintainer, who should be able to understand the system's intended behaviour from this document alone.

### 1.2 Scope

Salvorion supports emergency assembly accountability at NCU. It captures sign-in at assembly points via ID card scanning or manual entry, supports departmental roll calls by Safety Wardens, provides a real-time compliance dashboard, and generates and distributes reports automatically after each activation. Full scope boundaries are as stated in the Project Charter, sections 4.1 and 4.2, and are not repeated in full here except where a requirement needs the boundary to make sense.

### 1.3 Definitions

| Term | Meaning |
|------|---------|
| Activation | A single instance of the system being used to account for people: either a drill or a real emergency, from start to close |
| Assembly point | A physical location where people gather during an evacuation (e.g. Robinson Hall Greens) |
| Zone | A numbered grouping of areas that report to one assembly point, as defined in the OSH Emergency Assembly Point Guide |
| Area | A building, floor or department-level location that belongs to a zone |
| Warden | A Safety Warden, responsible for the roll call of a zone or area |
| Sign-in | The act of a person's presence being recorded at an assembly point, by scan or manual entry |
| Roll call | A warden's review of everyone expected in their area, marking each as present, absent or excused |
| Unaccounted | A person expected during an activation who has neither signed in nor been marked present, absent or excused |
| Accountability event | An immutable record of a single sign-in, roll-call mark, or visitor registration |
| Synthetic data | Fabricated but realistic data used for development and testing, containing no real personal information |

### 1.4 References

- Project Charter (Document 01)
- Proposal for OSH Review (Document 02)
- Technical Foundation (Document 03)
- Final Technology Stack (Document 04)
- NCU Emergency Assembly Point Guide (source document for zones, areas and assembly points)

### 1.5 Overview

Section 2 describes the system at a high level. Section 3 lists functional requirements by module. Section 4 lists non-functional requirements. Section 5 lists external interface requirements. Section 6 lists constraints and assumptions carried from the charter. Section 7 gives the traceability summary. Appendix A lists open items pending OSH confirmation.

---

## 2. Overall description

### 2.1 Product perspective

Salvorion is a new, standalone system. It is not a replacement for any existing NCU software. It consumes roster data from NCU's staff and student records (via the roster integration layer) and produces reports for people who are not system users (report recipients receiving email only). It has no dependency on any other NCU system to operate; roster and barcode integration are additive once available.

### 2.2 Product functions (summary)

1. Manage activations (start, monitor, close; drill or real)
2. Sign in staff, students and visitors at assembly points, by scan or manually
3. Register visitors and issue temporary passes
4. Conduct departmental and zone-based roll calls
5. Display live participation and non-compliance on a dashboard
6. Generate and distribute reports automatically
7. Manage rosters, locations, users, wardens and settings
8. Maintain a complete audit trail
9. Operate fully offline at the point of use, syncing when connectivity allows

### 2.3 User classes and characteristics

| User class | Description | Technical proficiency assumed |
|---|---|---|
| System Administrator | Configures the system: locations, roster imports, users, settings | Comfortable with admin software |
| OSH Officer | Starts and closes activations, monitors the dashboard, manages report recipients | General computer literacy |
| Safety Warden | Conducts roll calls at an assigned zone or area | Basic smartphone literacy; may be using the app under stress, outdoors, in bright sunlight |
| Report Recipient (no login) | Receives reports by email; not a system user | Email literacy only |
| Report Viewer (optional login role) | Read-only access to the dashboard and activation history, granted case by case | General computer literacy |
| Staff / Student / Visitor | Signs in with an ID card or gives details at the assembly point | None (interacts only with a warden or a scanning station, not with the app directly, in the first release) |

### 2.4 Operating environment

- Mobile client: Android and iOS, current and prior major OS version at minimum
- Web client: current versions of Chrome, Edge, Safari and Firefox
- Backend: containerised, deployed to a cloud host as described in the Final Technology Stack
- Network: assembly points may have no connectivity; the system must be designed on the assumption that this is the normal case, not the exception

### 2.5 Design and implementation constraints

- Must use the technology stack fixed in Document 04
- Must not require any change to NCU's existing ID cards
- Must not require real staff or student data before the pilot stage (Charter, section 9)
- Must accommodate the zone and area structure of the OSH Emergency Assembly Point Guide, including many-to-many area-to-department relationships (e.g. the Steel Building)

### 2.6 Assumptions and dependencies

As stated in the Project Charter, section 9, carried forward and not repeated here in full. The one addition specific to this SRS: the OSH Emergency Assembly Point Guide is assumed current as of its receipt; any discrepancy found during seeding (for example, the overlapping Robinson Hall and Hiram S. Walters entries noted on review) will be raised with OSH rather than silently resolved.

---

## 3. Functional requirements

Each requirement has an ID of the form `FR-<module>-<number>` for traceability. Priority: **M**andatory (Release 1), **S**hould-have (Release 1 if time allows), **L**ater (Release 2).

### 3.1 Activation management

| ID | Requirement | Priority |
|---|---|---|
| FR-ACT-01 | The system shall allow an OSH Officer to start an activation, specifying its type (drill or real) and scope (whole campus or selected zones). | M |
| FR-ACT-02 | Once an activation has started, its type shall not be changeable. | M |
| FR-ACT-03 | The system shall allow an OSH Officer to close an activation, which stops accepting new accountability events for it and triggers report generation. | M |
| FR-ACT-04 | The system shall maintain a history of all past activations, viewable by OSH Officers. | M |
| FR-ACT-05 | The system shall prevent two active activations from overlapping in the same zone at the same time. | S |
| FR-ACT-06 | The system shall record who started and who closed each activation, and when. | M |

### 3.2 Sign-in

| ID | Requirement | Priority |
|---|---|---|
| FR-SIGN-01 | The system shall allow a person's ID card to be scanned (barcode or QR) at an assembly point to record their sign-in. | M |
| FR-SIGN-02 | The system shall allow a person to be signed in manually by ID number when a card cannot be scanned. | M |
| FR-SIGN-03 | The system shall allow a person to be signed in manually by name search when their ID number is not known. | M |
| FR-SIGN-04 | Every manual sign-in shall record which user performed it, on which device, and at what time. | M |
| FR-SIGN-05 | Sign-in shall function with no network connectivity, queuing the event locally until it can be synchronised. | M |
| FR-SIGN-06 | A retried submission of the same accountability event (same client-generated identifier) shall not create a duplicate record. A second, distinct scan of a person already recorded present shall not change their status. | M |
| FR-SIGN-07 | The system shall provide immediate visual and audible confirmation of a successful or failed scan, usable in bright outdoor light. | M |

### 3.3 Visitor management

| ID | Requirement | Priority |
|---|---|---|
| FR-VIS-01 | The system shall allow a warden or reception user to register a visitor by name, host and contact number. | M |
| FR-VIS-02 | The system shall issue a temporary QR pass to a registered visitor for use during their visit. | M |
| FR-VIS-03 | Visitors shall be included in participation counts and non-compliance lists in the same way as staff and students. | M |
| FR-VIS-04 | Visitor personal details shall be automatically and permanently deleted after a configurable retention period (default 90 days). | M |

### 3.4 Roll calls

| ID | Requirement | Priority |
|---|---|---|
| FR-ROLL-01 | The system shall present a warden with the list of people expected in their assigned zone or area during an active activation. | M |
| FR-ROLL-02 | A person already signed in by scan or manual entry shall appear as present by default on the warden's roll-call list, requiring no further action unless the warden overrides it. | M |
| FR-ROLL-03 | The system shall allow a warden to mark a person as present, absent, or excused, with an optional note. | M |
| FR-ROLL-04 | Roll-call actions shall function with no network connectivity, queuing locally until synchronised. | M |
| FR-ROLL-05 | If a physical scan and a roll-call mark contradict each other for the same person in the same activation (e.g. scanned present but marked absent), the system shall treat the scan as authoritative for status and flag the contradiction for the warden's attention. | M |
| FR-ROLL-06 | The system shall show a warden a live count of how many people in their area remain unaccounted for. | M |
| FR-ROLL-07 | The system shall allow an OSH Officer or System Administrator to override a person's status (present, absent or excused) with a mandatory note, for example after confirming someone safe by phone. | M |

### 3.5 Dashboard

| ID | Requirement | Priority |
|---|---|---|
| FR-DASH-01 | The system shall display, for an active activation, the participation rate per department. | M |
| FR-DASH-02 | The system shall display, for an active activation, the participation rate per faculty. | M |
| FR-DASH-03 | The system shall display a list of unaccounted individuals, filterable by department, faculty or zone. | M |
| FR-DASH-04 | The dashboard shall clearly indicate whether the current activation is a drill or a real emergency, visually distinct from other content. | M |
| FR-DASH-05 | Dashboard figures shall update automatically as accountability events are synchronised, without requiring a manual refresh. | M |
| FR-DASH-06 | The system shall allow an OSH Officer to view the history of a past activation, including its final participation rates and non-compliance list. | M |
| FR-DASH-07 | The system shall display trend comparisons across multiple past activations. | L |

### 3.6 Reporting

| ID | Requirement | Priority |
|---|---|---|
| FR-REP-01 | The system shall automatically generate a report when an activation is closed. | M |
| FR-REP-02 | The report shall include: activation type, start and end time, participation rate per department and faculty, the list of unaccounted individuals, and a record of manual sign-ins made during the activation. | M |
| FR-REP-03 | The system shall automatically email the report to a configured list of recipients within 15 minutes of the activation closing. | M |
| FR-REP-04 | The system shall allow an OSH Officer to manage the list of report recipients without developer involvement. | M |
| FR-REP-05 | The system shall allow a report to be manually regenerated or re-sent on request. | S |
| FR-REP-06 | The system shall retain all generated reports and make them available for download from the activation history. | M |

### 3.7 Roster management

| ID | Requirement | Priority |
|---|---|---|
| FR-ROS-01 | The system shall support importing staff and student roster data from a file (CSV or Excel), with a validation preview before committing the import. | M |
| FR-ROS-02 | The system shall support generating synthetic roster data for development, testing and demonstration, indistinguishable in structure from real data but containing no real personal information. | M |
| FR-ROS-03 | The system shall record the history of every roster import, including counts and any errors encountered. | M |
| FR-ROS-04 | The system shall be designed so that a scheduled export or a direct database connection can be added as an additional roster source without changing any other part of the system. | M |
| FR-ROS-05 | The system shall support a configurable rule determining which students are considered "expected" during an activation (all enrolled, signed-in only, or timetable-based). | S (all-enrolled and signed-in-only in Release 1; timetable-based in Release 2) |

### 3.8 Locations and organisation

| ID | Requirement | Priority |
|---|---|---|
| FR-LOC-01 | The system shall allow an administrator to define assembly points, zones and areas, matching the structure of the OSH Emergency Assembly Point Guide. | M |
| FR-LOC-02 | The system shall support an area belonging to more than one department, and a department having areas in more than one zone. | M |
| FR-LOC-03 | The system shall allow an administrator to define departments, faculties and programmes, independently of the zone structure. | M |
| FR-LOC-04 | The system shall allow an administrator to assign a warden to one or more zones or areas, with an effective date range. | M |

### 3.9 User and access management

| ID | Requirement | Priority |
|---|---|---|
| FR-USR-01 | The system shall support the roles System Administrator, OSH Officer, Safety Warden and Report Viewer, each with a distinct set of permitted actions. Report recipients (email only) are not system users. | M |
| FR-USR-02 | The system shall allow an administrator to create, disable and reassign the role of a user account. | M |
| FR-USR-03 | The system shall require authentication for every role-restricted action; no accountability-affecting action shall be possible without an identified user. | M |
| FR-USR-04 | The system shall support login on a device with no network connectivity, using a previously cached credential, for a configurable grace period. | M |
| FR-USR-05 | The mobile app shall show a warden their own recent actions and the sync state of each (sent, queued), so they can confirm an action went through. | S |

### 3.10 Audit

| ID | Requirement | Priority |
|---|---|---|
| FR-AUD-01 | The system shall record every create, update and delete action with the acting user, the affected record, the time, and the device where applicable. | M |
| FR-AUD-02 | Audit records shall be immutable; no user role shall be able to edit or delete an audit record. | M |
| FR-AUD-03 | The system shall allow an administrator to view and filter the audit log. | M |

---

## 4. Non-functional requirements

| ID | Requirement | Priority |
|---|---|---|
| NFR-PERF-01 | The system shall support at least 50 concurrent wardens and 5,000 accountability events within a 15-minute activation without degradation of client responsiveness. | M |
| NFR-PERF-02 | A synchronised accountability event shall be reflected on the dashboard within 10 seconds under normal connectivity. | M |
| NFR-OFF-01 | All sign-in and roll-call functions shall be fully operable with zero network connectivity. | M |
| NFR-OFF-02 | A device's local queue shall hold at least 10,000 unsynchronised events without data loss. | M |
| NFR-OFF-03 | Queued events shall synchronise automatically within 60 seconds of connectivity becoming available, without user intervention. | M |
| NFR-OFF-04 | No accountability data shall be lost if the client app is closed, crashes, or the device restarts while events are queued. | M |
| NFR-AVAIL-01 | The backend shall target 99.5% availability outside planned maintenance. Client-side functions must degrade gracefully, not fail, during any backend outage. | M |
| NFR-SEC-01 | All network communication shall use TLS. | M |
| NFR-SEC-02 | Passwords shall be hashed using argon2 or equivalent; plaintext passwords shall never be stored or logged. | M |
| NFR-SEC-03 | Every API endpoint that affects or exposes accountability data shall enforce role-based access control. | M |
| NFR-SEC-04 | The client's local database shall be encrypted at rest. | M |
| NFR-PRIV-01 | Visitor personal data shall be purged automatically per FR-VIS-04, with the purge itself recorded in the audit log. | M |
| NFR-PRIV-02 | No personally identifiable information shall appear in application logs. | M |
| NFR-ACC-01 | The web dashboard shall meet WCAG 2.1 Level AA. | S |
| NFR-ACC-02 | The warden mobile interface shall use large touch targets and a high-contrast mode suitable for outdoor use under stress. | M |
| NFR-MAINT-01 | Every backend module shall have automated tests covering its core logic. | M |
| NFR-MAINT-02 | The API shall be documented via a generated OpenAPI specification kept in sync with the implementation. | M |
| NFR-USE-01 | A warden with no prior training shall be able to complete a roll call correctly within 10 minutes of first opening the app, guided only by on-screen instructions. | S |

---

## 5. External interface requirements

### 5.1 User interfaces

- Mobile application (Android, iOS): sign-in scanning, visitor registration, roll calls
- Web application: dashboard, administration, reporting, optionally read-only access for report recipients

### 5.2 Hardware interfaces

- Device camera, for barcode and QR scanning

### 5.3 Software interfaces

- Roster data source: file import in Release 1; scheduled export or direct database connection in later releases, via the roster integration layer described in Document 03
- Email delivery: Amazon SES
- Sync: PowerSync service, connected to PostgreSQL via logical replication

### 5.4 Communication interfaces

- HTTPS for all client-server API traffic
- PowerSync's own sync protocol for client data replication; both the mobile app and the web dashboard read live data through it
- WebSocket (Phoenix Channels) for out-of-band pushes that are not row replication (for example contradiction flags)

---

## 6. Constraints and assumptions

Carried from the Project Charter, sections 8 and 9, and not repeated in full. This SRS adds no new constraints beyond what is stated in sections 2.5 and 2.6 above.

---

## 7. Traceability summary

Each functional requirement in section 3 traces to an objective in the Project Charter, section 3:

| Charter objective | Related requirements |
|---|---|
| O1 (roll call under 5 minutes) | FR-ROLL-01 to FR-ROLL-06, NFR-USE-01 |
| O2 (real-time visibility) | FR-DASH-01 to FR-DASH-05, NFR-PERF-02 |
| O3 (identify unaccounted individuals) | FR-DASH-03, FR-ROLL-06 |
| O4 (automated reporting) | FR-REP-01 to FR-REP-06 |
| O5 (standardised reporting) | FR-REP-02, FR-REP-04 |
| O6 (offline operation) | FR-SIGN-05, FR-ROLL-04, FR-USR-04, NFR-OFF-01 to NFR-OFF-04 |

A full requirements traceability matrix, cross-referencing each requirement to its use case, design element and test case, will be produced once use cases and test cases exist (later deliverables in the design and testing phases).

---

## Appendix A: Open items pending OSH confirmation

These mirror the questions raised in the OSH Proposal (Document 02), section 6, restated here as the requirements that depend on each answer.

| Open question | Affected requirements | Interim approach |
|---|---|---|
| Report recipients | FR-REP-03, FR-REP-04 | Configurable list, empty until OSH names recipients |
| Student accountability rule | FR-ROS-05 | Signed-in-only default; timetable-based rule deferred to Release 2 |
| Student grouping | FR-DASH-02, FR-LOC-03 | Faculty and programme both modelled |
| Warden devices | NFR-ACC-02 | Designed for personal phones and shared tablets alike |
| ID barcode format | FR-SIGN-01 | Parser assumes payload is the ID number; adjustable once confirmed |
| Escalation on unaccounted individuals | FR-DASH-03 | Reported, not automated, in Release 1 |
| Retention period | FR-VIS-04 | Default 90 days, configurable |
| Report format | FR-REP-02 | Draft format proposed for OSH review before Release 1 |
