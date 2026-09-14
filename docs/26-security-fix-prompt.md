# Fix: Three Real Correctness/Privacy Risks Found by the Full Audit

**Document:** 26 of the project record
**Prepared:** 14 September 2026
**Priority:** Before anything else, including OpenAPI generation or Stage C.

---

## The prompt

```
The full consistency audit (Document 25) found three real correctness
or privacy risks, not documentation drift. Fix exactly these three, add
tests that would have caught each one, and record each as a
DECISIONS.md entry. Do not fix anything else from that audit in this
prompt — it will be triaged separately.

FIX 1 (critical): event attribution can be forged
lib/salvorion_web/controllers/event_controller.ex currently does
Map.put_new("recorded_by_id", conn.assigns.current_user_id, params) —
if the request body already contains recorded_by_id, the client's
value wins. Accountability.ingest_event/2 then authorises the
"override" kind by looking up THAT id's role, not the authenticated
caller's. Fix:
- The controller must always overwrite recorded_by_id with
  conn.assigns.current_user_id, unconditionally — never Map.put_new,
  never trust a client-supplied value for this field, full stop.
- If device_id is present in the request, validate it belongs to the
  authenticated user (a device row with that id and user_id matching
  the caller) — do not accept an arbitrary device_id either.
- Add a test: authenticate as a warden, POST an event with
  recorded_by_id set to a different (osh_officer) user's id and
  kind "override" — assert this is now rejected as
  :override_not_permitted (evaluated against the WARDEN's real role,
  not the forged id), not accepted.
- Add a second test: any event (not just override) posted with a
  forged recorded_by_id records the AUTHENTICATED user as
  recorded_by_id in the resulting event and audit row, never the
  forged value.
- DECISIONS.md entry: name the vulnerability, the fix, and that the
  pre-existing test suite passed despite this because no test had ever
  sent recorded_by_id in a request body.

FIX 2: activation starter and start time can be forged
lib/salvorion/activations.ex's start_activation/2 (or
schedule_activation/2) uses put_new for started_by_id and started_at,
and ActivationController.create passes raw request params through.
Fix:
- Always set started_by_id from the authenticated user, never from
  params, in both schedule_activation/2 and start_activation/2.
- Always set started_at to DateTime.utc_now() at the moment of the
  call, never from params — an activation cannot be backdated.
- Update schedule_activation/2's own documentation, which currently
  claims started_by_id "is not accepted in attrs" — make that claim
  true, or correct the doc to match whatever the fixed behavior
  actually is.
- Add a test: an OSH officer starts an activation with started_by_id
  and started_at supplied in the request, naming a different user and
  a backdated time — assert both are ignored and the real caller/real
  current time are used instead.
- DECISIONS.md entry: name this, and note the consequence this closes
  (backdating shifts warden scope pinning and every dashboard figure
  computed from started_at).

FIX 3: visitor purge leaves personal data in the audit log
Roster.purge_expired_visitors/1 correctly anonymises the Person row,
but the visitor.registered audit row written at registration time
(roster.ex, register_visitor/2) stores the visitor's name, phone,
email and host in its `after` payload, and nothing ever touches it.
Fix:
- Change what register_visitor/2 writes into the audit payload for
  visitor.registered: store only non-personal fields (person_id,
  pass_code/id_number, visitor_expires_at) — never name, phone, email,
  or host in the audit log for this specific action. This does lose
  some forensic detail from the audit trail; say so explicitly in
  DECISIONS.md as the accepted trade-off, and note that the
  ReportDelivery/email records (also not purged, per the audit's
  finding) are a separate, smaller residual gap not fixed here since
  emails already sent cannot be recalled — record that as a known,
  accepted limitation distinct from this fix.
- Add a test: register a visitor, inspect the resulting audit_logs
  row's `after` payload, and assert no name/phone/email/host field is
  present.
- Add a test: register a visitor, purge them (per the existing purge
  test pattern), and confirm the ORIGINAL registration audit row is
  now already free of personal data (nothing further needs to happen
  to it at purge time, because it was never written there).
- DECISIONS.md entry: name the gap the audit found, the fix, and the
  accepted residual gap (already-sent report emails/PDFs).

VERIFICATION
 1. mix compile clean; mix precommit passes; report the new test count.
 2. For each fix, show the specific new test failing against the OLD
    code (git stash the fix, run just that test, show it fails) is not
    required — instead, clearly state in prose what result the test
    would have shown before the fix, so I can verify the test is
    actually meaningful rather than checking something that was never
    broken.
 3. Confirm no other behavior changed — run the full suite, confirm
    the count only grew by the new tests, nothing pre-existing broke.
 4. Show the three DECISIONS.md entries in full.
 5. Confirm CI is still green after pushing.

Stop after verification. Do not start on any other finding from
Document 25 — those will be triaged in a separate pass.
```
