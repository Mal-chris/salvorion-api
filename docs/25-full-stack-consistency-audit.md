# Full-Stack Consistency Audit (Post Stage B)

**Document:** 25 of the project record
**Purpose:** Document 13 audited the plans before any code existed. This audits the other direction — twelve prompts of actual implementation, against the documents that were supposed to govern it, and against DECISIONS.md's own accumulated record of every place the implementation legitimately departed from a document. Stage B is complete; this is the checkpoint before the OpenAPI/Dart-client bridge into Flutter.
**Environment:** WSL2 Ubuntu, inside `~/salvorion`, run through Claude Code
**Prepared:** 14 September 2026
**Read-only.** This prompt produces a report. It does not fix anything. A second prompt, built from what this one finds, will apply fixes deliberately and one category at a time — the same two-step shape Document 13 used.

---

## The prompt

```
This is a full consistency audit of Salvorion after Stage B (Prompts
1-12, all complete: scaffold, Accounts/Audit, Organisation/Locations,
Roster, Activations, Accountability, roll-call/dashboard reads,
Visitors, routes, PowerSync sync, Reporting, Channels). Read-only —
report findings, do not fix anything, do not run mix format, do not
touch any file.

READ, IN FULL, BEFORE ANALYSING ANYTHING:
- Every file in docs/ (01 through 24)
- docs/DECISIONS.md, in full, start to finish
- Every Ecto schema under lib/salvorion/*/*.ex
- Every migration under priv/repo/migrations/
- lib/salvorion_web/rbac.ex and lib/salvorion_web/router.ex, in full
- lib/salvorion_web/plugs/authorize.ex and
  lib/salvorion_web/channels/*.ex
- The moduledoc of every context module (Accounts, Organisation,
  Locations, Roster, Activations, Accountability, Reporting, Audit,
  Settings)

Do not rely on memory of what a document says or what a prompt asked
for — several documents were revised mid-project (Document 03's
sections 2/3/5/7/8/9 were rewritten after Document 04; Document 06 has
been edited at least four times for schema changes made along the way)
and DECISIONS.md is the authoritative record of every deliberate
departure. A finding that a document doesn't match DECISIONS.md is a
real gap. A finding that the CODE doesn't match a document AND
DECISIONS.md never explains why is a more serious gap — it means a
decision was made and never recorded, which is exactly what this audit
exists to catch.

CHECK THESE CATEGORIES, in order, and report EVERY finding, not just
the ones that seem important — a full accounting matters more than a
short report:

1. SCHEMA VS DOCUMENT 06. For every table: does docs/06's entity
   listing match the actual migration and schema file, field for
   field? Known changes to specifically verify were actually applied
   to Document 06 and not just to code: person_statuses'
   contradicting_event_id/contradiction_resolved_at, devices'
   revoked_at, accountability_events' kind list (now five values, not
   four), the sync_safe_users view, the Oban tables, any table added
   entirely after Document 06 was written (report_deliveries'
   relationship to Reporting, if anything there drifted).

2. RBAC MATRIX VS ACTUAL ROUTES. For every route in router.ex, does
   rbac.ex's entry match what docs/10 section 1 actually says, OR does
   DECISIONS.md explicitly justify the difference? List every route
   where you cannot find either a matching matrix row or a DECISIONS.md
   entry explaining the departure. Known departures to confirm are
   documented, not just implemented: Organisation writes being
   admin-only (not admin+osh_officer like Locations), the shared event-
   ingestion endpoint's role union, GET /api/activations/:id extended
   to warden, device-revoke's owner-or-admin controller check having no
   matrix row at all.

3. SRS (Document 05) VS IMPLEMENTATION. For every FR-* and NFR-*
   requirement: implemented as specified, implemented differently (and
   is that difference in DECISIONS.md?), or not implemented at all
   (and is that a stated Release 2 deferral, or silently missing)?
   Pay particular attention to FR-ROS-05 (the three accountability
   rules), FR-REP-05 (regenerate — confirm it creates new rows, matches
   Prompt 11), and every FR-DASH-* (confirm participation_rate/
   accounted_rate as actually built match what Document 05 describes).

4. ARCHITECTURE DOCUMENTS (07, 08) VS REALITY. The read/write split,
   the PowerSync-vs-Channels division of responsibility, the sequence
   diagrams' description of sign-in/report-generation/contradiction
   flows — do these still describe what the code does? Known revisions
   to confirm landed correctly: PowerSync's confirmed Sync Streams
   mechanism (not the sync-rules format the diagrams may still name),
   the warden-scope pinning difference between the HTTP roll-call
   endpoint (activation start) and PowerSync sync streams (necessarily
   current-time), and Channels' actual scope (a lightweight nudge, not
   row replication) versus anything in Document 07 that could be read
   as more expansive.

5. DECISIONS.md INTERNAL CONSISTENCY. Read the whole file as one
   document, not a series of unrelated entries. Are there two entries
   that describe the same subject differently (for example, does
   anything written before Prompt 6's follow-up still describe
   contradiction_resolved_at as unrecoverable on rebuild, after the
   later entry says it is now an event and I4 holds)? Is any entry
   clearly superseded by a later one but not marked as such?

6. BUSINESS PROCESS / WIREFRAMES (09, 11) VS WHAT ACTUALLY EXISTS.
   Document 09's escalation process names an override action — does
   FR-ROLL-07 and the actual override implementation match what that
   diagram describes? Document 11's screens reference specific fields
   and actions — does anything it describes not actually exist yet, or
   exist under a different name/shape than described?

7. NAMING AND TERMINOLOGY DRIFT. Role names, event kind names, status
   values, function names referenced in docs versus their actual names
   in code (e.g., does any document still say a function name that was
   renamed during implementation?).

8. THE "THINGS OSH MUST CONFIRM" LIST. Cross-check this list of
   operational decisions against DECISIONS.md and confirm each is
   actually traceable to a DECISIONS.md entry, and that none is missing
   from DECISIONS.md even though it's clearly a real, documented
   decision in code:
   - staff-by-location expectation for zones-scope activations
   - the 5-minute late-field-event window vs. no window for review
     actions
   - participation_rate vs accounted_rate as the headline dashboard
     figure
   - warden scope fixed at activation start (HTTP) vs. current-time
     (PowerSync) vs. also-current-time (Channels, per Prompt 12)
   - an expired visitor pass still being accepted when scanned
   - visitor retention (90 days default) and the retroactive-lowering
     behavior
   - the two unresolved area overlaps in the OSH assembly point guide
     (Robinson Hall, Hiram S. Walters Resource Centre)
   - department/faculty/programme writes being admin-only, unlike
     locations
   - the shared event-ingestion endpoint's role-union gap
   - PowerSync replicating a revoked device's data for up to 15 minutes
   - the same gap NOT existing for Channels (5-minute self-check) — and
     confirm this asymmetry itself is recorded plainly somewhere a
     non-technical reader could find it, not just inferred from two
     separate DECISIONS.md entries
   Report which of these are cleanly documented, which are documented
   but hard to find, and which are missing entirely.

9. TEST COVERAGE SANITY CHECK. Not a full coverage audit — just: does
   every context module have a corresponding test file, and does the
   test count in the most recent CI run (253) match what you'd expect
   given the modules that exist? Flag anything that looks like a
   context with no tests at all, if one exists.

OUTPUT FORMAT: one numbered finding per issue, grouped by the nine
categories above, each finding stating: what the document says, what
the code/DECISIONS.md actually shows, and a suggested resolution
(update the document, update DECISIONS.md, or — only if you find an
actual functional gap, not just a documentation gap — flag it as
something needing a real code change). Do not apply any of these
resolutions. End with a short summary: total findings per category,
and which ONE finding, if any, looks like a genuine correctness risk
rather than documentation drift.
```

---

## What to do with the result

Don't ask Claude Code to fix anything in the same session. Paste the full report back. I'll go through it the same way Document 13's findings were triaged — sorted by consequence, with a recommendation per finding — and we'll write a second, scoped fix-it prompt from that, the same two-step shape as the very first audit. Given this is running on Opus and covering a much larger surface than Document 13 did, expect this to take a while and to be worth reading in full rather than skimming the summary at the end.
