# Business Process Models

**Document:** 09 of the project record
**Version:** 0.2 (Draft; revised 11 September 2026 per Document 13)
**Date:** 8 September 2026
**Prepared by:** Malik Christopher
**Status:** For review

These diagrams describe the operational processes Salvorion supports, at the level a non-technical reader (OSH, a warden, a report recipient) can follow. They sit above the sequence diagrams in Document 08, which show how the software implements each step; these show what happens and who is responsible for it, independent of implementation. Written in Mermaid flowchart syntax.

---

## 1. Drill or emergency activation process

```mermaid
flowchart TD
    A([Alarm sounds or drill scheduled]) --> B{Real emergency or drill?}
    B -->|Real| C[OSH Officer or designated staff starts activation: type = real]
    B -->|Drill| D[OSH Officer starts activation: type = drill, at scheduled time]
    C --> E[System locks activation type; cannot be changed]
    D --> E
    E --> F[System notifies dashboard: activation is now live]
    F --> G[Staff, students and visitors evacuate to assembly points]
    G --> H[Wardens begin sign-in and roll call at each assembly point]
    H --> I[OSH monitors live dashboard for participation and unaccounted individuals]
    I --> J{All zones accounted for, or all-clear given?}
    J -->|No| I
    J -->|Yes| K[OSH Officer closes the activation]
    K --> L[System generates and distributes report]
    L --> M([Process ends])
```

**Responsible parties:** OSH Officer (start/close, monitor), Safety Wardens (sign-in, roll call), all campus occupants (evacuate and sign in). The distinction between real and drill is made once, at the very start, and is irreversible for the rest of the process, matching FR-ACT-02.

---

## 2. Sign-in process (at the assembly point)

```mermaid
flowchart TD
    A([Person arrives at assembly point]) --> B{ID card available?}
    B -->|Yes| C[Warden or self-service station scans barcode/QR]
    C --> D{Scan successful?}
    D -->|Yes| E[Person recorded as present]
    D -->|No, card damaged/unreadable| F[Warden enters ID number manually]
    B -->|No, card lost/forgotten| G[Warden searches by name]
    B -->|No ID at all, visitor| H[Warden registers visitor: name, host, contact]
    F --> E
    G --> E
    H --> I[Visitor issued temporary QR pass]
    I --> E
    E --> J{Device online?}
    J -->|Yes| K[Record sent to server immediately]
    J -->|No| L[Record stored on device, sent automatically once connectivity returns]
    K --> M([Person appears as present on dashboard and warden's roll-call list])
    L --> M
```

**Responsible parties:** the person signing in, and the warden or self-service station operating the scanner. Every manual path (F, G, H) is logged with who performed it, satisfying FR-SIGN-04.

---

## 3. Departmental roll call process

```mermaid
flowchart TD
    A([Activation is active]) --> B[Warden opens roll-call list for their zone/area]
    B --> C[List shows everyone expected, pre-marked present if already signed in]
    C --> D{Warden reviews each remaining person}
    D --> E{Present, but not yet scanned?}
    E -->|Yes| F[Warden marks present manually, with note if needed]
    E -->|No| G{Confirmed absent from the area at time of activation?}
    G -->|Yes| H[Warden marks absent, with reason if known]
    G -->|No, cannot be confirmed| I[Person remains unaccounted]
    F --> J[Status updates on dashboard in real time]
    H --> J
    I --> J
    J --> K{All persons in this zone reviewed?}
    K -->|No| D
    K -->|Yes| L[Warden reports zone as complete to OSH]
    L --> M([Zone roll call finished])
```

**Responsible parties:** Safety Wardens. The "unaccounted" outcome (branch I) is what feeds the non-compliance list on the dashboard (FR-DASH-03) and is the trigger for any escalation, described next.

---

## 4. Escalation for unaccounted individuals

Release 1 keeps this manual, per the SRS (Appendix A: "escalation remains a manual OSH process in the first release"). This diagram documents the intended manual process so it is consistent across departments even without system automation.

```mermaid
flowchart TD
    A([Roll call closes with one or more unaccounted persons]) --> B[Dashboard displays unaccounted list to OSH, filterable by zone/department]
    B --> C[OSH Officer reviews list]
    C --> D{Person confirmed safe by another means? e.g. phone call, seen elsewhere}
    D -->|Yes| E[OSH Officer overrides status to excused, with a mandatory note - FR-ROLL-07]
    D -->|No| F[OSH escalates to Security and Risk Management / emergency responders]
    F --> G[Search or follow-up conducted per NCU's existing emergency procedures]
    G --> H{Person located?}
    H -->|Yes| E
    H -->|No| I[Escalation continues per NCU emergency protocol, outside this system]
    E --> J([Status reflected in final report])
    I --> J
```

**Responsible parties:** OSH Officer for the initial review and decision to escalate; Security and Risk Management or emergency responders for the physical search. The system's role ends at surfacing the list accurately and quickly (FR-DASH-03); it does not automate contact, search or dispatch in Release 1. This is the clearest candidate for Release 2 automation (e.g. automatic SMS to an unaccounted person's emergency contact) once OSH has operational experience with the manual version.

---

## 5. Automated report distribution process

```mermaid
flowchart TD
    A([Activation closed]) --> B[System compiles: participation rates, unaccounted list, manual sign-in log]
    B --> C[System renders report to PDF]
    C --> D[System retrieves active report recipient list]
    D --> E{Any active recipients configured?}
    E -->|No| F[Report stored, marked undelivered; dashboard shows a persistent banner that no recipients are configured]
    E -->|Yes| G[System emails PDF to each active recipient]
    G --> H{Delivery successful for this recipient?}
    H -->|Yes| I[Delivery marked sent]
    H -->|No| J[Delivery marked failed; retried automatically per standard retry policy]
    I --> K{All recipients processed?}
    J --> K
    K -->|No| G
    K -->|Yes| L[Activation marked as reported]
    F --> L
    L --> M([Process ends; report remains available in activation history])
```

**Responsible parties:** the system performs this process without human involvement (FR-REP-01, FR-REP-03), except for the exception path (E → F), where OSH is expected to configure at least one recipient before relying on the process. OSH remains responsible for managing the recipient list itself (FR-REP-04), which is why branch F exists as a distinct, visible failure mode rather than a silent no-op.

---

## 6. Notes on how these differ from the sequence diagrams (Document 08)

- These process models describe **what happens and who is accountable**, in language OSH and wardens can validate directly against real drill procedure.
- The sequence diagrams describe **how the software implements each step**, including which service calls which, and are the ones a developer works from.
- Where the two overlap (sign-in, report generation), they should never contradict each other. If a future change to the software changes a business rule (for example, if escalation becomes automated in Release 2), both documents need updating together.
