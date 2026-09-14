# Prompt 12: Phoenix Channels

**Document:** 24 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 13 (completing it — the query and PubSub-broadcast half was Prompt 7)
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 14 September 2026

---

## Why this prompt exists

Prompt 7 built `Phoenix.PubSub.broadcast/3` after every commit, and it works, verified with `assert_receive` in-process. But nothing outside the Elixir application can hear it. Document 07 names Phoenix Channels as the client-facing half of this specifically: "out-of-band pushes that are not row replication" (the contradiction flag; a live nudge to refresh, since PowerSync's own replication is not instant). Without this prompt, that broadcast has no way to reach a connected device at all.

Have Claude Code read `docs/07-c4-architecture-diagrams.md` (the Phoenix Channels component and its note on scope), `docs/08-sequence-state-deployment-diagrams.md` sections 1–3, and `docs/10-security-design.md` section 4 (device revocation) before starting.

---

## The prompt

```
This is the twelfth step in building Salvorion. Prompts 1–11 (complete)
built every context, routes, PowerSync sync, and Reporting. This prompt
completes the real-time layer: a Phoenix Channel a client joins to
receive the PubSub broadcasts Prompt 7 already produces.

Read docs/07-c4-architecture-diagrams.md, docs/08-sequence-state-deployment-diagrams.md
sections 1–3, and docs/10-security-design.md section 4 before starting.

The payload this pushes is deliberately lightweight — a nudge, not the
data itself. PowerSync remains the source of truth a client reads for
the actual row; this channel exists so a client does not have to wait
for PowerSync's own replication cadence to know something changed.

TASK 1: UserSocket
Create lib/salvorion_web/channels/user_socket.ex:
- connect/3 verifies the presented token via Guardian (same
  verification SalvorionWeb.Plugs.Authorize already performs — extract
  the shared logic into a function both call, do not duplicate the
  Guardian.decode_and_verify call and its error handling a second time)
  and, if the token carries a device_id claim, checks
  devices.revoked_at exactly as the plug does. Reject the connection
  (return :error) on an invalid/expired token or a revoked device —
  never accept a socket and reject later at join.
- Assigns current_user_id, current_role, current_device_id to the
  socket on success.
- id/1 returns "user_socket:#{user_id}" — needed for Task 4.
- Wire it into the endpoint (a "/socket" mount, websocket: true).

TASK 2: ActivationChannel
Create lib/salvorion_web/channels/activation_channel.ex, topic
"activation:*":
- join/3 verifies the activation (by the id in the topic) exists ->
  {:error, %{reason: "not_found"}} if not. Every one of the four roles
  (admin, osh_officer, warden, report_viewer) may join — this mirrors
  the "View live dashboard" RBAC row, where every role has at least
  some form of Yes.
- For admin, osh_officer, report_viewer: no further scoping. Every
  push for this activation reaches them.
- For warden: compute Scope.warden_scope/2 ONCE, at join, using the
  activation's started_at as of (matching how
  Accounts.effective_warden_assignments/2 is already pinned for the
  HTTP roll-call endpoint — consistency with what the client will
  actually fetch matters more here than matching PowerSync's
  necessarily-different, always-current scoping). Store the resulting
  zone_ids in the socket's channel assigns. A warden with no effective
  assignment for this activation may still join (so they at least
  receive activation_changed events) but receives no
  person_status_updated pushes — do not error the join for this case.
- handle_info for {:person_status_updated, payload} (subscribed via
  Accountability.subscribe/1 in join/3, as an ordinary GenServer-style
  info message the channel process receives): for admin/osh_officer/
  report_viewer, push it through unfiltered. For warden, push it ONLY
  if payload.zone_ids intersects the socket's stored zone_ids;
  otherwise silently drop it (do not push a filtered/redacted version —
  either the whole event or nothing).
- handle_info for {:activation_changed, payload}: push to everyone
  joined, unconditionally, regardless of role (activation status is
  not scoped).
- The pushed payload strips zone_ids before sending (that field exists
  for server-side filtering only; a client has no use for it and it is
  extra information about zone attribution the payload does not need
  to expose).

TASK 3: Long-lived connections and revocation — a real gap, addressed
here rather than left to Prompt 10's PowerSync precedent
A joined Channel can stay open far longer than an HTTP request or even
a typical PowerSync reconnect cycle — hours, in principle. Task 1's
connect-time check is not enough on its own: a device revoked five
minutes into an hour-long connection would keep receiving pushes for
the rest of that hour. Address this directly:
- In ActivationChannel, schedule a recurring self-check (e.g. every 5
  minutes via Process.send_after/3) that re-queries the socket's
  device_id (if any) for revoked_at. If now revoked, push a
  {event: "session_revoked"} message and terminate the channel
  (which closes the client's subscription; it does not need to affect
  other channels/sockets for the same user on other devices).
- Do the same for token expiry — recompute against the token's own
  exp claim (already available from Task 1's decode) rather than
  re-verifying the whole token every 5 minutes.
- Record the exact interval chosen and why (balance: shorter is safer,
  costs a small periodic query per open channel; 5 minutes is a
  starting number, not a documented requirement — say so, and that
  this is more responsive than the PowerSync gap documented in Prompt
  10, which cannot do this at all since PowerSync's protocol has no
  equivalent server-push disconnect for an already-open connection —
  confirm this claim against PowerSync's documentation before stating
  it as fact, don't assume it symmetrically).

VERIFICATION
Use Phoenix.ChannelTest (native, well-suited to this — no external
client needed the way Prompt 10 needed one for PowerSync's raw
protocol). Reset dev DB to baseline first if not already. Create O1
(osh_officer), W5 (warden, Zone 5, assigned before any activation used
in these tests starts), W8 (warden, Zone 8), R1 (report_viewer).

 1. mix compile clean; mix precommit passes; test count.
 2. Connect UserSocket with a valid token -> success, assigns correct.
    With an expired token -> connection refused. With a revoked
    device's token -> connection refused (create the device, revoke
    it, then attempt to connect with a token carrying that device_id).
 3. Start a campus activation. O1, W5, W8, R1 all join
    "activation:<id>" successfully. A join attempt for a nonexistent
    activation id fails with reason "not_found".
 4. Ingest a scanned event for a person in a Zone 5 area. Confirm O1,
    W8... wait, confirm O1 and R1 both receive the
    person_status_updated push (assert_push). Confirm W5 receives it.
    Confirm W8 does NOT (refute_push). Show the pushed payload does not
    contain a zone_ids key.
 5. A warden with no effective assignment for this activation (create
    one, W_none) joins successfully but receives no
    person_status_updated push for the same event from item 4
    (refute_push), while still receiving the activation_changed push
    from item 6.
 6. Close the activation. Confirm ALL FOUR joined sockets from item 3
    (O1, W5, W8, R1) receive activation_changed, unfiltered by scope.
 7. Task 3: create a device for W5, join with a token carrying its
    device_id. Revoke the device. Rather than waiting 5 real minutes,
    send the channel process the internal check message directly (or
    reduce the interval via test config) and confirm it pushes
    session_revoked and the channel terminates. Do the same for a
    token you construct with an already-past exp claim.
 8. Confirm the PowerSync-cannot-force-disconnect claim from Task 3
    against real documentation, and report what you found — correct it
    here if it turns out PowerSync does have some equivalent
    mechanism, rather than letting a false claim stand in
    DECISIONS.md.
 9. Every file created or modified, and the DECISIONS.md text added.

Stop after verification. This closes Stage B. Do not start on OpenAPI
generation or the Dart client.
```

---

## What to check yourself

1. **Item 4's `refute_push` for W8 is the actual point of this whole prompt.** An `assert_push` that passes is easy; a `refute_push` that passes for the right reason (the message was never sent, not merely not yet delivered) is what proves the scoping works. Read how the test distinguishes "never sent" from "sent but not yet arrived" — `Phoenix.ChannelTest`'s `refute_push` has a timeout window for exactly this reason; confirm it's long enough to be meaningful.
2. **Item 5 is a small but real judgment call worth rereading.** A warden with no assignment still joining, rather than being refused, means the channel doesn't become a second RBAC gate duplicating the HTTP layer's `{:error, :no_assignment}` — it just quietly delivers nothing useful to them. Decide for yourself whether that's the right user experience or whether it should be denied outright; either is defensible, but Document 10 doesn't settle it and I didn't either, so this is genuinely yours to confirm.
3. **Item 8 matters beyond this one prompt.** If Claude Code's claim about PowerSync's own limits turns out wrong, that doesn't just correct a sentence in DECISIONS.md, it changes how serious a gap Prompt 10's item 7 (revoked-device-keeps-syncing) actually is, and that item is already on the list of things for OSH to know about. Check this one before treating that entry as final.
4. **Skim the 5-minute revocation-check interval and decide if it's the number you want.** It is stated as a starting choice, not a requirement — cheap to tighten or loosen once you've thought about it, expensive to forget was ever a knob.
