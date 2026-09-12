# Project Charter

**Project name:** Emergency Assembly Accountability and Compliance Tracking System
**Working title:** Salvorion (proposed; see section 14)
**Organisation:** Northern Caribbean University (NCU)
**Requesting department:** Department of Occupational Health and Safety (OSH), Office of Security and Risk Management (SRM)
**Document version:** 0.3 (Draft; revised 11 September 2026 per the consistency audit, Document 13)
**Date:** 1 September 2026
**Prepared by:** Malik Christopher
**Document status:** For OSH review

---

## 1. Purpose of this document

This charter defines the scope and objectives of the project, identifies the principal stakeholders, and records the constraints and assumptions under which the project will be delivered. It is the reference point against which later scope decisions are measured. Once accepted by OSH, changes to scope are recorded through the change control process in section 13.

---

## 2. Background and problem statement

During fire drills and actual emergency evacuations, NCU currently accounts for staff, students and visitors at assembly points using manual methods. This produces several recurring problems:

- Roll calls are slow, and the time to confirm that a department is fully accounted for is measured in many minutes rather than seconds.
- Records are paper-based or ad hoc, so participation data is inconsistent between departments and difficult to compare.
- Missing or unaccounted individuals are identified late, if at all, delaying any search or escalation.
- Compliance reporting to the relevant parties is manual, delayed, and formatted differently depending on who prepares it.
- There is no single, authoritative view of campus-wide accountability during an activation.

The result is reduced accuracy, slower decisions during the period when speed matters most, and weak accountability for departmental compliance.

---

## 3. Project objectives

The system will improve the accuracy, speed and accountability of emergency assembly during drills and real activations, and will produce consistent compliance reporting across all departments and faculties.

Measurable objectives (targets are proposed defaults, to be confirmed with OSH during requirements analysis):

| # | Objective | Proposed target |
|---|-----------|-----------------|
| O1 | Reduce time to complete a departmental roll call | Under 5 minutes from arrival at assembly point |
| O2 | Provide real-time visibility of accountability status | Dashboard reflects a sign-in within 10 seconds when online; within 60 seconds of reconnection when offline |
| O3 | Identify unaccounted individuals per department | Non-compliance list available before the roll call is closed |
| O4 | Automate post-activation reporting | Report generated and distributed to the relevant parties (e.g. HR, Deans, SRM) within 15 minutes of an activation being closed |
| O5 | Standardise reporting across departments | One report format, one data source, no manual compilation |
| O6 | Operate without network connectivity | Full sign-in and roll-call capability offline, with automatic sync |

---

## 4. Scope

### 4.1 In scope

**Populations accounted for**

- Staff (academic and administrative), organised by department
- Students, organised by faculty and programme, with accountability rules to be defined with OSH (see section 9)
- Visitors, registered on entry or at the assembly point, with a temporary identifier

**Core functions**

1. **Activation management.** Creating, starting and closing an activation, and distinguishing a drill from a real emergency in all data and reports.
2. **Electronic sign-in at assembly points.** Scanning the barcode or QR code on existing NCU ID cards, with manual fallback (ID number entry and name search) and an audit trail for every manual entry.
3. **Visitor registration.** Lightweight capture of visitor details and host, issuance of a temporary QR pass, and inclusion of visitors in accountability counts.
4. **Departmental roll calls.** Safety Wardens confirm presence, absence or excused status for each expected person in their area of responsibility, digitally and offline if necessary.
5. **Offline-first operation.** All warden and sign-in functions work with no connectivity, store data locally, and synchronise automatically when a connection is available, with defined conflict resolution.
6. **Centralised reporting dashboard.** Real-time participation rates per department and faculty, non-compliance lists of missing or unaccounted individuals, and activation history.
7. **Automated reporting.** Generation of a standard report at the close of each activation and automatic distribution to a configurable list of relevant parties (e.g. HR, Deans, SRM). Recipients are configured by OSH, not fixed in the software.
8. **Roster management.** A roster integration layer that imports staff and student rosters and organisational mappings from NCU's existing systems via direct database connection, scheduled export, or file import, with support for scheduled refresh. Development and testing use synthetic data.
9. **User and access management.** Role-based access for System Administrators, OSH officers, Safety Wardens, and report recipients.
10. **Audit logging.** An immutable record of who recorded what, when, and from which device.

**Platforms**

- Mobile application (Android and iOS) for Wardens and sign-in stations
- Web application for the dashboard, administration and reporting
- Backend services and database

### 4.2 Out of scope

- Replacement or redesign of NCU ID cards
- Emergency alerting or mass notification (sirens, SMS blasts, public address)
- Integration with fire alarm panels or building management systems
- Physical access control or door hardware
- Timetable or class scheduling systems (the system consumes timetable data if provided; it does not manage it)
- HR or student information system functions beyond roster import
- Multi-campus deployment in the first release (the data model will support it; the release will target the main campus)

Items in this list may be proposed for later phases through the change control process.

---

## 5. Key deliverables

| Phase | Deliverables |
|-------|-------------|
| Planning | Project charter, stakeholder register and RACI, feasibility study, risk register, project schedule |
| Requirements | Software Requirements Specification, personas, use cases, user stories with acceptance criteria, traceability matrix, business process models |
| Design | Architecture document (C4), ERD and data dictionary, Ecto schema and migrations, API specification, sequence and state diagrams, offline sync design, security design, wireframes, deployment plan, test strategy |
| Development | Backend services, mobile application, web application, seed data and drill simulator |
| Testing | Unit, integration, end-to-end, load and offline test results; UAT sign-off |
| Deployment | Deployment runbook, administrator manual, warden quick-reference guide, training plan, pilot drill report, maintenance plan |

---

## 6. Stakeholders

| Role | Interest in the project | Responsibility |
|------|------------------------|----------------|
| OSH (requesting department) | Owns the business need; accepts scope and deliverables | Accepts charter, SRS and releases; defines process rules |
| SRM (parent office) | Oversight of safety and risk; likely report recipient | Confirms reporting expectations |
| Safety Wardens | Conduct roll calls at assembly points | Provide field requirements; participate in UAT and pilot drills |
| Human Resources | Owns staff roster; likely report recipient | Provides roster access; confirms report content |
| Deans | Likely report recipients for faculty and student compliance | Confirm report content |
| UNISS (IT Services) | Owns existing databases, network, hosting and security policy | Provides roster data access; approves hosting and security approach |
| Registrar / Student Affairs | Owns student roster and timetable data | Provides data access; advises on student accountability rules |
| Staff, students and visitors | Subjects of accountability | Sign in at assembly points |
| Project Lead / Developer (Malik Christopher) | Delivers the system | Requirements, design, development, testing, handover |

Report recipients are listed as "likely" pending confirmation by OSH. A full stakeholder register and RACI matrix follow this charter as a separate document.

---

## 7. High-level requirements summary

Detailed requirements are recorded in the SRS. The headline requirements are:

- The system must function fully offline at assembly points and synchronise on reconnection.
- The system must accept existing NCU ID cards as the primary identifier, with manual fallback.
- Every accountability action must be attributable to a user, a device and a timestamp.
- Drills and real activations must be distinguishable in every record and report.
- Reports must be generated automatically and delivered to a configurable recipient list without manual intervention.
- Personal data must be handled in accordance with the Jamaican Data Protection Act, including defined retention periods, particularly for visitor data.
- The system must support concurrent use by all wardens across campus during a single activation without degradation.

---

## 8. Constraints

| Constraint | Implication |
|------------|-------------|
| No consistent campus WiFi or mobile data at assembly points | Offline-first architecture is mandatory |
| Existing ID cards must be used as-is | Barcode symbology and encoded value must be confirmed with UNISS before design closes |
| Solo developer engagement; commercial terms not yet agreed | Scope must be phased; first release focuses on core accountability and reporting; costing and terms to be settled with OSH after requirements are confirmed |
| No fixed deadline | Schedule is milestone-driven rather than date-driven; the pilot drill is the natural forcing function |
| Real roster data unlikely to be released before a working system exists | Build and test with synthetic data; implement a roster integration layer (direct connection, scheduled export, or file import) so real data can be connected at pilot stage without redesign |
| Running costs should be modest | Prefer low-cost infrastructure; hosting and service costs recorded in the feasibility study |

---

## 9. Assumptions

- NCU will describe the structure of its staff and student roster data (field names and formats, including the identifier encoded on ID cards) early in the project, and will provide real data, or a connection to it, at pilot stage under agreed data protection arrangements.
- Wardens will use personal smartphones or university-issued devices capable of running a mobile app with camera access.
- Student accountability will be signed-in-only in Release 1 (students who sign in are counted; no expected list is enforced) and timetable-based in Release 2, subject to confirmation with OSH and the Registrar.
- Report recipients will accept a standard PDF report delivered by email as the primary reporting mechanism.
- UNISS will approve a cloud-hosted deployment, or provide an on-premises alternative.

Any assumption that proves false will be treated as a risk and managed through the risk register.

---

## 10. Initial risks

| # | Risk | Likelihood | Impact | Initial response |
|---|------|-----------|--------|------------------|
| R1 | Roster data structure unknown, or real data not released for pilot | Medium | High | Confirm field structure early; develop with synthetic data; build an adapter-based integration layer supporting direct connection, export and file import |
| R2 | ID card barcode does not encode a usable identifier | Medium | High | Confirm symbology and payload in the first week; fallback to app-generated QR |
| R3 | Sync conflicts between devices produce incorrect accountability status | Medium | High | Define deterministic conflict rules in design; test explicitly |
| R4 | Wardens lack suitable devices or refuse to use personal phones | Medium | Medium | Confirm device policy with OSH; budget for a small tablet pool if needed |
| R5 | Student accountability rules prove too complex for the first release | High | Medium | Phase student accountability; deliver staff and visitor accountability first if necessary |
| R6 | Data protection obligations not addressed | Low | High | Include retention and access rules in the SRS; review with a responsible officer |
| R7 | Single-developer availability | Medium | Medium | Milestone-based schedule; comprehensive documentation to allow handover |

A full risk register with owners and review dates follows as a separate document.

---

## 11. Milestones

| Milestone | Exit criteria |
|-----------|--------------|
| M1 Charter accepted | OSH confirms scope and objectives |
| M2 Requirements baselined | SRS accepted; ID card payload, roster data structure and report recipients confirmed |
| M3 Design complete | Architecture, data model, API specification and sync design reviewed |
| M4 Backend alpha | Roster import, activations, sign-in, roll call and reporting APIs functional with seed data |
| M5 Client alpha | Mobile and web clients functional online and offline against the backend |
| M6 Integrated beta | End-to-end drill simulation passes; load and offline tests pass |
| M7 Pilot drill | Real roster data connected under agreed data protection arrangements; system used in a live drill with a subset of departments; UAT sign-off |
| M8 Release | Full deployment, training delivered, handover documentation accepted |

Dates will be assigned in the project schedule once M2 has confirmed the critical dependencies.

---

## 12. Success criteria

The project will be considered successful when:

1. A full drill can be conducted with all wardens using the system, without paper fallback.
2. The dashboard shows accurate per-department and per-faculty participation during the drill.
3. Unaccounted individuals are listed before the drill is closed.
4. The relevant parties receive the standard report automatically after the drill closes.
5. The system operates correctly at assembly points with no connectivity.
6. OSH accepts the system for ongoing operational use.

---

## 13. Acceptance and change control

| Role | Name | Signature | Date |
|------|------|-----------|------|
| OSH representative | | | |
| UNISS representative | | | |
| Project Lead | Malik Christopher | | |

**Change control.** Changes to the scope, objectives or constraints in this charter are to be raised in writing with the Project Lead, assessed for impact on schedule and design, and confirmed with OSH before implementation.

---

## 14. Naming

NCU systems follow an "-orion" naming convention (Aeorion for the student-facing system; Solorion for the graduation system). The proposed name for this system is **Salvorion**, from the Latin *salvus* (safe), reflecting the system's purpose of confirming that everyone is safe and accounted for. Alternatives, should OSH prefer another: Vigilorion, Presorion, Sentorion. The final name is to be confirmed by OSH.
