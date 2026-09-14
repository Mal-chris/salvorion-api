# Wireframes and UI Specification

**Document:** 11 of the project record
**Version:** 0.2 (Draft; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** For review. Three key screens were also rendered as visual mockups in-conversation for immediate feedback; this document is the durable, complete specification covering every screen, including ones not mocked up visually. Revised 14 September 2026 (closing Document 25's findings 6.4, 6.5, 6.6): the roll-call "Present" group renamed "Accounted" to match the API's actual grouping (which includes present, absent and excused, not present-only), the contradiction "confirm" action corrected to describe ingesting a `contradiction_resolved` event rather than a direct column write, "Mark zone complete" marked explicitly as not yet implemented, and the dashboard's unaccounted-row "last known status source" field corrected — it is always nil by definition for a genuinely unaccounted person.

---

## 1. Mobile app (Warden and sign-in station)

### 1.1 Scan / sign-in screen (primary screen, opens by default when an activation is active)

- Header: current zone/assembly point name, activation type badge (visually distinct colour for drill vs real, per FR-DASH-04's principle applied to the mobile app too)
- Central scan target: live camera viewfinder with a bounded scan area; instant visual (border flash) and audible confirmation on successful scan (FR-SIGN-07)
- Immediately below the scanner: result of the last scan (name, status), auto-clearing after a few seconds
- Two secondary actions, always visible without scrolling: "Enter ID manually" and "Search by name" (FR-SIGN-02, FR-SIGN-03)
- One tertiary action: "Register a visitor" (FR-VIS-01)
- Footer strip: three counters, signed in / unaccounted / queued offline. The "queued offline" counter is the one piece of UI unique to this system's offline requirement; it must never read as an error state, since a nonzero queue during normal offline operation is expected, not a fault.

### 1.2 Manual ID entry (modal or full-screen, reached from 1.1)

- Numeric keypad optimised for ID number entry
- An optional free-text note field (every accountability event carries a `note`); the audit trail required by FR-SIGN-04 is recorded automatically and is invisible to the warden
- Confirm button disabled until a valid-length ID is entered

### 1.3 Name search (reached from 1.1)

- Search-as-you-type field
- Results list showing name, department/programme, and a "select" action
- Empty state: "No match. Check the ID number or register as a visitor," linking directly to 1.4, since a failed name search is the single most likely path to a visitor registration for someone who legitimately has no record

### 1.4 Visitor registration

- Fields: name, host (searchable against staff/student directory), contact number
- On submit: QR pass displayed full-screen with a "done" action, large enough to be scanned back by a warden later without the visitor needing to do anything further

### 1.5 Roll call

- Grouped list: Unaccounted (top, most urgent), Flagged/contradictions (FR-ROLL-05), **Accounted** (collapsed by default, since they need no action — corrected from an earlier draft's "Present": the actual API group (`Accountability.list_roll_call/2`'s `accounted` list) contains everyone with status `present`, `absent`, *or* `excused`, not present-only people; "Accounted" is the name that actually matches what the group contains)
- Each unaccounted row: name, usual area, two actions (Present / Absent), with an optional note field reachable by long-press or a small icon, not a separate screen (keeping the primary action fast, per NFR-USE-01's ten-minute target)
- Flagged rows are visually distinct (warning colour, not danger colour, since a contradiction needs review, not alarm) and carry a single "confirm" action that accepts the scan's status — this **ingests a `contradiction_resolved` event** through the same path as any other accountability event, not a direct write; `contradiction_resolved_at` is then a derived field, computed from that event (corrected from an earlier draft that described this as directly setting the column; see Document 06 and `docs/DECISIONS.md`, "Accountability core (Prompt 6): contradiction resolution is an event")
- Footer action: "Mark zone complete" — **not yet implemented** (Document 25, finding 6.4): no route, event kind, or field exists anywhere in the backend for a warden to signal this. This remains a reasonable aspiration for a later Stage C screen, described here as a design intent, not as something the API already supports; do not build a client screen assuming a backend endpoint for it exists yet.

### 1.6 Offline indicator (persistent, not a separate screen)

- A small, unobtrusive banner or icon state change (not a modal, not a blocking dialog) whenever the device has no connectivity, and a corresponding change when it reconnects and the queue drains. This must never interrupt an in-progress scan or roll-call action.

### 1.7 Login

- Email and password fields, standard
- A visible note when operating on a cached/offline credential (FR-USR-04), so a warden understands why they weren't asked to re-enter a password mid-drill

---

## 2. Web app (OSH Officer, Administrator)

### 2.1 Live dashboard (default landing screen for OSH Officer role)

- Header: activation name/description, start time, activation type badge
- Two headline metric cards: total signed in, total unaccounted
- Participation-by-faculty (or department, toggle between the two) as horizontal progress bars, colour-coded by threshold (comfortably above target, borderline, concerning) rather than a single flat colour, so a glance tells OSH where to look first
- Unaccounted list, grouped and filterable by zone, department or faculty (FR-DASH-03), each row showing name and usual area — **not** a "last known status source" (corrected from an earlier draft, Document 25 finding 6.6): a row appears on this list precisely *because* no status-determining event exists for that person in this activation, so there is nothing to show as a source; the field this earlier draft described is always nil for a genuinely unaccounted person by definition, not merely blank pending data
- All figures update live without a manual refresh (FR-DASH-05)

### 2.2 Activation control (start/close)

- A clear, deliberately friction-having "Start activation" action requiring an explicit choice of type (drill/real) and scope (campus/zones) before confirming, since this choice is irreversible (FR-ACT-02) and should never be a misclick
- Once active, a similarly deliberate "Close activation" action, with a summary of current participation shown before confirming, so OSH doesn't close prematurely

### 2.3 Activation history

- List of past activations: date, type, duration, final participation rate, link to that activation's report
- Selecting one reopens a read-only version of the dashboard as it stood at close, plus the generated report

### 2.4 Administration: locations

- Table view of assembly points, each expandable to its zones, each expandable to its areas
- Add/edit forms matching the OSH Emergency Assembly Point Guide's structure directly, including multi-select for an area's associated departments (FR-LOC-01, FR-LOC-02)

### 2.5 Administration: organisation

- Simple CRUD tables for faculties, departments, programmes (FR-LOC-03)

### 2.6 Administration: people and roster

- Roster import screen: file upload, a validation preview table (showing what will be created/updated/flagged as an error) before committing (FR-ROS-01), and import history below it (FR-ROS-03)
- People directory: searchable table, mainly for troubleshooting ("why isn't this person appearing"), not a primary daily-use screen

### 2.7 Administration: users and wardens

- User list with role and active/inactive toggle (FR-USR-02)
- Warden assignment screen: assign a user to a zone or area with a date range (FR-LOC-04), shown against the same location hierarchy as 2.4 so the mapping is visually obvious

### 2.8 Administration: report recipients and settings

- Simple list with add/remove/active-toggle for recipients (FR-REP-04)
- Settings screen exposing the configurable rules from the SRS Appendix A (student accountability rule, visitor retention period, offline login grace period) as plain-language toggles or dropdowns, not raw key/value editing, since OSH Officers edit these (Document 10, RBAC)

### 2.9 Audit log (Administrator only)

- Filterable table: actor, action, entity, timestamp; each row expandable to see before/after values (FR-AUD-03)

---

## 3. Navigation structure

**Mobile app**, bottom navigation (three items, matching the warden's actual workflow, not a generic template): Scan, Roll Call, Activity (their own recent actions with sync state, FR-USR-05, mainly for reassurance that something they did actually went through).

**Web app**, left sidebar: Dashboard, History, Locations, Organisation, Roster, Users & Wardens, Recipients & Settings, Audit Log. Sidebar items beyond Dashboard and History are visible only to roles permitted to use them, per the RBAC matrix in the Security Design document (10).

---

## 4. Visual language notes

- Drill and real activations must be distinguishable at a glance everywhere the activation appears, not just on the dashboard. The proposed convention: an amber/warning-coloured badge for drills, a red/danger-coloured badge for real activations, present on both the mobile scan screen and every web screen showing activation context.
- The unaccounted count is the single most important number in the system and should be the most visually prominent figure on both the warden's footer strip and the OSH dashboard.
- Large touch targets throughout the mobile app (NFR-ACC-02), since wardens may be operating the device one-handed, outdoors, in bright sunlight, and possibly under stress. Buttons for Present/Absent on the roll-call screen should be no smaller than a normal thumb's tap target, not compact table-row buttons.

---

## 5. Relationship to the mockups shown in conversation

Three screens (mobile scan/sign-in, mobile roll call, web dashboard) were rendered as interactive visual previews earlier in this session, matching sections 1.1, 1.5 and 2.1 above respectively. Those previews are illustrative and not saved as project files; this document is the specification of record. When Stage C development reaches each screen, build against the requirements and layout described here, using the visual previews only as a starting reference for spacing and hierarchy.
