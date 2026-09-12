# Emergency Assembly Accountability System

## Proposal and Requirements Summary for OSH Review

**Prepared for:** Mr. Shaun Wellington, Head of Occupational Health and Safety (OSH), Office of Security and Risk Management (SRM)
**Prepared by:** Malik Christopher
**Date:** 1 September 2026
**Version:** 0.1 (Draft for review)

---

## 1. Purpose of this document

This document sets out my understanding of what OSH has asked for, how I propose to deliver it, and the decisions I need from OSH before detailed design begins. It is written to be read in one sitting. Where I have made an assumption, it is marked, and section 6 gathers every open question in one place.

Please treat everything here as a proposal. Nothing is fixed until OSH confirms it.

---

## 2. What the system will do

The system gives OSH a single, real-time view of who has and has not been accounted for at assembly points during a drill or a real emergency, and produces a consistent report afterwards without anyone having to compile it by hand.

### 2.1 At the assembly point

- Staff, students and visitors sign in by having the barcode on their existing NCU ID card scanned with a phone or tablet.
- Anyone without a card (lost, forgotten, or a visitor) can be signed in manually by ID number or name search. Every manual sign-in is recorded with who entered it and when.
- Visitors can be registered quickly with their name, host and contact number, and issued a temporary QR pass.
- Everything works without WiFi or mobile data. The device stores the records and sends them to the central system as soon as it has a connection.

### 2.2 Roll calls

- Safety Wardens see a list of the people they are responsible for and mark each one as present, absent or excused.
- People who have already been scanned at the assembly point appear as present automatically, so wardens only need to deal with the exceptions.
- Roll calls also work offline.

### 2.3 The dashboard

- OSH sees, live, the participation rate for every department and faculty, and a list of every person not yet accounted for.
- The dashboard clearly shows whether the current activation is a drill or a real emergency.
- Past activations are kept for comparison and trend reporting.

### 2.4 Reporting

- When an activation is closed, the system produces a standard report automatically.
- The report is emailed to a list of recipients that OSH configures. It is not fixed in the software, so it can be changed at any time without a developer.
- The proposed default content is: activation type, start and end times, participation rate per department and faculty, the list of unaccounted individuals, and a record of any manual sign-ins.

### 2.5 Administration

- OSH staff can manage assembly points, warden assignments, report recipients and system settings.
- Staff and student rosters are imported from NCU's existing systems rather than maintained by hand. The system is designed to connect to those systems, or to accept an export from them, without needing changes on their side.
- All actions in the system are logged for audit purposes.

---

## 3. What the system will not do (in this phase)

To keep the first release achievable, the following are deliberately excluded. Any of them can be considered for a later phase.

- Replacing or redesigning ID cards
- Sending emergency alerts (sirens, SMS blasts, public address)
- Connecting to fire alarm panels or building systems
- Controlling doors or physical access
- Managing timetables
- Deployment to campuses other than the main campus (the design will allow for this later)

---

## 4. Who will use it

| Role | What they do in the system |
|------|---------------------------|
| OSH officers | Start and close activations, watch the dashboard, manage settings and recipients |
| Safety Wardens | Scan ID cards, register visitors, conduct roll calls |
| Report recipients (e.g. HR, Deans, SRM) | Receive reports by email; may be given read-only dashboard access |
| System Administrator | Manage user accounts and roster imports |
| Staff, students and visitors | Present an ID card or give their details at the assembly point |

---

## 5. How it will be delivered

I will follow a standard software development life cycle: requirements, design, development, testing, a pilot drill, then full release. OSH will be asked to review and confirm documents at the end of each stage, and to take part in the pilot drill.

OSH has not set a deadline, but I intend to deliver in a timely manner and will hold myself to the indicative schedule below. Windows are counted from the date OSH returns feedback on this document, since that feedback sets the direction of the work.

| Stage | Indicative window | What OSH receives |
|-------|------------------|-------------------|
| Requirements confirmed | Within 2 weeks of feedback | Detailed requirements specification for confirmation |
| Design complete | Within 5 weeks | Screen mock-ups and a walkthrough of how the system will work |
| Working build for review | Within 10 to 12 weeks | A demonstration OSH can try on their own devices |
| Pilot drill | To be scheduled with OSH, targeted for the following drill cycle | Live use with a subset of departments |
| Full release | Within 2 weeks of a successful pilot | Deployed system, training and documentation |

Costs, including hosting and email service fees, will be set out in a separate note once the scope is confirmed.

I do not need access to real staff or student data to build the system. Development and testing will use synthetic data, and the system will be built with a roster integration layer that can connect to NCU's existing databases, accept a scheduled export, or import a file, whichever UNISS prefers. Real data will only be needed at the pilot stage, once OSH and UNISS have had the chance to review a working system and agree the appropriate data protection arrangements.

Two things do need attention early, neither of which involves handing over personal data:

1. **The shape of the roster data.** I need to know which fields exist for staff and students (for example, ID number, name, department, faculty, programme) so the system can be built to match them. A description of the fields, or a sample with dummy values, is sufficient.
2. **Details of the ID card barcode.** I need to know what the barcode encodes and in what format, so the scanner can match it to the roster. A single card can be tested without recording any personal details.

---

## 6. Decisions and information needed from OSH

The following items shape the design. For each one I have set out the approach I intend to take. I will proceed with that approach unless OSH indicates otherwise. Where a question has not yet been decided within OSH, "not yet decided" is a useful answer in itself, and I will design the system to accommodate more than one outcome.

| # | Question | My proposed approach |
|---|----------|------------------------------|
| 1 | Who should receive the automated report after each activation? | The recipient list will be configurable by OSH at any time. I will need OSH to name the initial recipients. |
| 2 | How should student accountability work: every enrolled student, or only students expected on campus at the time (based on timetable, residence, or a class sign-in)? | If timetable data is available, the system will treat students who are expected on campus at the time as the accountable group. If it is not, the first release will count the students who sign in without checking them against an expected list. I am happy to talk this one through with OSH, as it may not have a settled answer yet. |
| 3 | Should students be grouped by faculty, by programme, by residence hall, or some combination? | Students will be grouped by faculty, with programme available as a secondary breakdown. |
| 4 | What devices will wardens use: personal phones, university-issued tablets, or a mix? | Wardens will use their personal phones, supported by a small pool of shared tablets at busy assembly points. |
| 5 | What does the ID card barcode encode, and what format is it? | I will confirm this with UNISS. |
| 6 | How many assembly points are there, and which departments report to each? | I will need OSH to provide this. |
| 7 | Is there an existing list of Safety Wardens and their areas of responsibility? | I will need OSH to provide this. |
| 8 | How should a drill be distinguished from a real emergency when starting an activation? | The officer will select the activation type when starting it. The type cannot be changed once the activation has started. |
| 9 | What should happen when someone is still unaccounted for when the roll call closes? Is there an escalation step the system should support? | The report will list everyone still unaccounted for. Any escalation will remain a manual OSH process in the first release. |
| 10 | How long should attendance records and visitor details be kept? | Attendance records will be kept indefinitely to preserve compliance history. Visitor personal details will be deleted after 90 days. |
| 11 | Is there a target time within which the report should be delivered after an activation closes? | The report will be delivered within 15 minutes of the activation being closed. |
| 12 | Are there existing report formats or compliance templates the report should resemble? | I will assume there is none and propose a format for OSH to review. |
| 13 | Does the system name need approval? Following NCU convention (Aeorion, Solorion), I propose **Salvorion**, from the Latin *salvus* (safe). | The system will be called Salvorion unless OSH prefers an alternative. |

---

## 7. What happens next

1. OSH reviews this document and returns comments or confirmations on the items in section 6.
2. I confirm the roster data structure and ID card barcode format with UNISS (IT Services), with OSH's introduction if needed.
3. I produce the detailed requirements specification for OSH to confirm.
4. Design and development begin, with periodic check-ins and a pilot drill at the end.

Please direct comments and questions to me directly. I am happy to walk through any part of this in person.

Malik Christopher
