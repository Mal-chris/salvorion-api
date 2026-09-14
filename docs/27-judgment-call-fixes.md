# Fix: Judgment Calls from the Full Audit

**Document:** 27 of the project record
**Prepared:** 14 September 2026
**Corresponds to:** Document 25 findings 2.5, 2.6, 2.7, 2.9, 2.11, 3.4, 3.14

---

## Decisions being implemented (already made; do not re-litigate)

- People lookups (`/api/people*`) widen to all four roles, including report_viewer — directory information, matches PowerSync's existing full-roster sync.
- The live unaccounted list (`.../dashboard/unaccounted`) narrows: report_viewer loses access. A real-time list of who is missing during a live activation is more sensitive than a finished report.
- Report listing/download stays open to report_viewer, and Document 10 §2 is corrected to say so explicitly.
- Warden writes (roll-call marks, contradiction resolution) become zone-scoped, matching the read side. Sign-in stays unscoped — anyone can legitimately sign in at any assembly point.
- A settings API route is built: there is currently no way for OSH to change `student_accountability_rule` or `visitor_retention_days` without direct database access, which contradicts Document 02's premise that these are OSH's decisions.
- Visitors never appearing on the unaccounted list is accepted as a real, permanent limitation (no roster exists to compare against), documented plainly, not engineered around.
- Deactivated users get the same treatment revoked devices already get: checked in the auth plug, the socket, and the Channel's periodic self-check.

---

## The prompt

```
This is a follow-up to the full consistency audit (Document 25) and
the security fix (Document 26, already applied). It implements four
already-decided judgment calls. Do not revisit the decisions
themselves — they are settled; implement them.

TASK 1: Widen people-lookup routes to all four roles
In lib/salvorion_web/rbac.ex, change GET /api/people, GET
/api/people/:id, and GET /api/people/lookup from
[admin, osh_officer, warden] to all four roles including report_viewer.
Update the corresponding controller tests. Add a DECISIONS.md entry
citing Document 10 §2 (directory information, visible to any
authenticated role) and noting this aligns the HTTP route with what
PowerSync's sync config already does.

TASK 2: Narrow the unaccounted-list route
In rbac.ex, remove report_viewer from
GET /api/activations/:id/dashboard/unaccounted specifically (leave the
other four dashboard routes — summary, departments, faculties, zones —
as they are; only unaccounted is being narrowed, since it's the one
that's operationally sensitive in a way an aggregate count isn't).
Update/add a controller test confirming report_viewer now gets 403 on
this one route specifically while still succeeding on the other four
dashboard routes and on report listing/download. Add a DECISIONS.md
entry explaining why this one route is narrower than its four
siblings.

TASK 3: Document report access for report_viewer explicitly
No code change (the routes already allow this). Update
docs/10-security-design.md section 2 to state plainly that
report_viewer may list and download generated reports, and add a
DECISIONS.md entry closing this finding (2.7) as "already correct;
document updated."

TASK 4: Scope warden writes to their own zone
- Add Accountability.person_in_warden_scope?/3 (or reuse/extend the
  existing Scope module) — given a warden's user, an activation, and a
  person, return whether that person is in the warden's scope, using
  the exact same logic list_roll_call/2 already uses (Scope.warden_scope/2
  plus the roster-or-event-location rule from Prompt 7).
- In ingest_event/2, when the authenticated caller's role is warden AND
  the event kind is "roll_call": the target person must be in that
  warden's scope for this activation, or return
  {:error, :outside_warden_scope}. Do NOT add this restriction to
  "scanned", "manual", or "visitor_registered" — sign-in anywhere
  remains legitimate. "override" and "contradiction_resolved" are
  already restricted to admin/osh_officer by the existing check, so
  this new restriction only ever applies to a warden's roll_call
  events; it never fires for the roles that are exempt from it anyway.
- Apply the same scope check to resolve_contradiction/3 when the
  caller is a warden.
- Map {:error, :outside_warden_scope} to 403 in FallbackController.
- Add tests: a Zone 5 warden's roll_call mark on a Zone 8 person is
  rejected; the same warden's roll_call mark on a Zone 5 person
  succeeds; the same warden's SCAN of a Zone 8 person still succeeds
  (proving sign-in is correctly exempt); an admin/osh_officer's
  roll_call mark on anyone, anywhere, is unaffected (they have no
  scope restriction at all).
- DECISIONS.md entry citing Document 10 §1's "own assigned zone/area
  only" and explaining why sign-in is deliberately excluded from this
  restriction.

TASK 5: A settings API route
- New routes: GET /api/settings (admin, osh_officer — returns every
  known setting key with its current value or documented default) and
  PATCH /api/settings/:key (admin, osh_officer — calls
  Settings.put_setting/3 with the authenticated user as actor).
- Validate known keys and their value shapes at this layer before
  calling put_setting/3: student_accountability_rule must be one of
  "signed_in_only"/"all_enrolled" ("timetable_expected" is accepted as
  a stored value but the controller should warn in its response body
  that it is not yet functional, matching the ArgumentError
  start_activation/2 already raises for it — do not let this route
  make choosing that value look fully supported when it currently
  isn't); visitor_retention_days must be a positive integer. Reject
  anything else with 422 before it reaches the database, rather than
  letting an invalid value cause the 500 the audit found at activation
  start (finding 3.6).
- Add controller tests for both routes, including the validation
  rejection cases and the timetable_expected warning.
- DECISIONS.md entry closing this finding.

TASK 6: Document the visitor unaccounted-list limitation plainly
No code change. Add a DECISIONS.md entry, written for a non-technical
reader as much as the rest of the file allows, stating: a visitor who
registers but never reaches an assembly point cannot appear on any
unaccounted list, because "unaccounted" only has meaning for someone
the system expected in advance, and there is no roster to expect a
visitor against. This is a permanent characteristic of visitor
handling, not a bug. Cross-reference FR-VIS-03 and Document 05
Appendix A.

TASK 7: Extend deactivation checks to match device revocation
- In SalvorionWeb.Plugs.Authorize (or wherever Guardian.verify_access_token/1
  lives, per the Prompt 12 refactor), after resolving the user, also
  check users.active — reject (401) if false, exactly like a revoked
  device.
- In UserSocket.connect/3, the same check at connect time.
- In ActivationChannel's periodic self-check (Prompt 12, Task 3), add
  a users.active check alongside the existing device-revocation and
  token-expiry checks, pushing the same session_revoked event and
  terminating if the user has since been deactivated.
- Add tests: a deactivated user's existing token is rejected on the
  next HTTP request; a deactivated user cannot open a new socket
  connection; an already-open channel terminates on its next
  self-check after the user is deactivated mid-connection (same
  pattern as the existing device-revocation test).
- DECISIONS.md entry noting this closes the gap symmetrically with
  device revocation, and update the existing "three tiers" language
  (if any exists from Prompt 12) to include user deactivation as a
  fourth checked condition, not just device revocation and token
  expiry.

VERIFICATION
 1. mix compile clean; mix precommit passes; new test count.
 2. Confirm report_viewer: 200 on GET /api/people, GET
    /api/activations/:id/reports and its download route; 403 on GET
    .../dashboard/unaccounted; 200 on the other four dashboard routes.
 3. Confirm a Zone 5 warden's roll_call mark on a Zone 8 person is
    403 :outside_warden_scope, their scan of the same Zone 8 person is
    201, and an admin's roll_call mark on that same person from any
    zone still succeeds.
 4. GET /api/settings as admin shows every known key. PATCH with an
    invalid student_accountability_rule value returns 422 before
    touching the database. PATCH with "timetable_expected" succeeds
    but the response includes the not-yet-functional warning.
 5. A deactivated user: existing token now rejected on the next API
    call, cannot open a new socket, and an already-open channel
    receives session_revoked within one self-check interval of being
    deactivated (use the same test-acceleration technique as the
    existing revocation tests).
 6. Full suite pass/fail counts, before and after.
 7. All six DECISIONS.md entries, in full.
 8. CI green after push.

Stop after verification.
```
