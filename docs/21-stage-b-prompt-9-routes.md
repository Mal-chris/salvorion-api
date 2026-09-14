# Prompt 9: Routes and Controllers

**Document:** 21 of the project record
**Corresponds to:** Technical Foundation (03), Stage B item 15 (partial — the HTTP layer; OpenAPI generation itself is a later prompt)
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 13 September 2026

---

## Scope note

Every context prompt from 3 through 8 deferred routes deliberately. This prompt pays that off: controllers and routes for Accounts, Organisation, Locations, Roster (including visitors), Activations, and Accountability, all behind the `Authorize` plug from Prompt 2. It does **not** cover PowerSync sync configuration (Prompt 10) or Reporting (Prompt 11, nothing to route to yet).

The RBAC matrix in `docs/10-security-design.md` section 1 is the source of truth. It has a documented limitation (Document 07, section 3's reading notes): it says who may call a route, not who may see which record. Two consequences for this prompt:

- A warden's "own zone only" restrictions are not expressible as a role list on a shared route. They are implemented by having the warden-facing endpoints call the functions that already take the current user and derive scope from it (`list_roll_call/2`, `count_unaccounted_for_warden/2`), never `list_roll_call_for_zone/2` (which has no such restriction and is for OSH/Admin).
- Where the table's intent is ambiguous for a route this prompt is about to create, Claude Code must say so and pick the more restrictive reading, not guess permissively. List every such case in the verification report.

Have Claude Code read `docs/10-security-design.md` in full before starting, not just section 1.

---

## The prompt

```
This is the ninth step in building Salvorion. Prompts 1–8 (complete)
built every context through Visitors. This prompt adds the HTTP layer:
controllers and routes, all authorised against docs/10-security-design.md
section 1. Do not touch PowerSync config or build the Reporting context.

Read docs/10-security-design.md in full before starting.

TASK 1: Response conventions
- A shared error-mapping layer (a Phoenix FallbackController, referenced
  from `action_fallback` in every controller below) that maps context
  return values to HTTP responses, applied consistently:
    {:error, %Ecto.Changeset{}}        -> 422, {errors: %{field: [msg]}}
    {:error, :not_found}               -> 404
    {:error, :unknown_person}          -> 404
    {:error, :no_assignment}           -> 403
    {:error, :not_a_warden}            -> 403
    {:error, :zone_conflict, msg}      -> 409, {error: msg}
    {:error, :activation_not_started}  -> 409
    {:error, :activation_closed}       -> 409
    {:error, :override_not_permitted}  -> 403
    {:error, :no_open_contradiction}   -> 409
    {:error, :invalid_credentials}     -> 401
    anything else                      -> 500, logged with the actual
                                           reason (never swallow an
                                           unrecognised error into a
                                           generic message without
                                           logging what it actually was)
- Every success response is {data: ...} or {data: [...], meta: {...}}
  for paginated/filtered lists (paginate list_people/1 and
  list_audit_logs/1 only — everything else here returns small enough
  sets that pagination is not needed yet; note in DECISIONS.md that
  large-list pagination is deferred, not forgotten).
- Every list endpoint that accepts filters validates unknown query
  params are ignored, not silently misapplied (a typo'd filter name
  should return the unfiltered list, not a 500).

TASK 2: RBAC wiring
Extend SalvorionWeb.RBAC (from Prompt 2) with an entry for every route
in Tasks 3–8, using the naming already established
(admin, osh_officer, warden, report_viewer). For each entry, cite which
row of docs/10 section 1 it implements in a code comment. Where a row's
intent cannot be expressed as a route-level role list (the "own zone
only" cases), the comment must say so and name the context function
that does the actual scoping instead.

TASK 3: Accounts routes
  POST   /api/auth/login                    public (exists)
  POST   /api/auth/refresh                  public (exists)
  GET    /api/auth/me                       any authenticated (exists)
  POST   /api/users                         admin only
  GET    /api/users                         admin only
  GET    /api/users/:id                     admin only
  PATCH  /api/users/:id/role                admin only
  POST   /api/users/:id/deactivate          admin only
  POST   /api/devices                       any authenticated (self)
  POST   /api/devices/:id/revoke            admin, or the device's own
                                             user (check in the
                                             controller, not just RBAC)
  POST   /api/warden-assignments            admin, osh_officer
  GET    /api/warden-assignments            admin, osh_officer

TASK 4: Organisation routes
  GET    /api/faculties                     any authenticated
  POST   /api/faculties                     per docs/10 — determine and
                                             cite the row; if organisation
                                             management is not explicitly
                                             listed separately from
                                             locations, say so and apply
                                             the same permission as
                                             "Manage assembly points,
                                             zones, areas" with a note
                                             asking me to confirm
  GET    /api/departments, POST /api/departments        (same pattern)
  GET    /api/programmes,  POST /api/programmes          (same pattern)

TASK 5: Locations routes
  GET    /api/assembly-points               any authenticated
  POST   /api/assembly-points               admin, osh_officer
  GET    /api/assembly-points/hierarchy     any authenticated (the
                                             get_assembly_point_hierarchy/0
                                             tree, for the future admin
                                             screen)
  GET    /api/zones,  POST /api/zones        admin, osh_officer (write)
  GET    /api/areas,  POST /api/areas        admin, osh_officer (write)
  POST   /api/areas/:id/departments          admin, osh_officer (link)
  DELETE /api/areas/:id/departments/:dept_id admin, osh_officer (unlink)

TASK 6: Roster routes
  GET    /api/people                        admin, osh_officer, warden
                                             (a warden needs this for
                                             manual/name-search sign-in,
                                             FR-SIGN-02/03 — not
                                             restricted to their own
                                             zone, since anyone could
                                             walk up to any assembly
                                             point)
  GET    /api/people/:id                    admin, osh_officer, warden
  GET    /api/people/lookup?id_number=...   admin, osh_officer, warden
                                             (the scan-resolution path;
                                             404 via :unknown_person,
                                             not an empty list)
  POST   /api/roster-imports                admin only (file upload —
                                             use Plug.Upload; validate
                                             content-type is text/csv;
                                             reject anything else before
                                             it reaches FileImportProvider)
  GET    /api/roster-imports                admin only
  POST   /api/visitors                      admin, osh_officer, warden

TASK 7: Activations routes
  POST   /api/activations                   osh_officer ONLY — cite the
                                             DECISIONS.md note from
                                             Prompt 5 in the RBAC comment
                                             so nobody later widens this
                                             to match Locations
  PATCH  /api/activations/:id/close         osh_officer ONLY
  POST   /api/activations/:id/start         osh_officer ONLY (starting a
                                             previously scheduled one)
  GET    /api/activations                   admin, osh_officer,
                                             report_viewer
  GET    /api/activations/:id               admin, osh_officer,
                                             report_viewer, warden (a
                                             warden may view the
                                             activation they're working,
                                             just not the full history
                                             list — this is a case worth
                                             flagging per the scope note
                                             above)

TASK 8: Accountability routes
  POST   /api/activations/:id/events        admin, osh_officer, warden
                                             (sign-in kinds; the
                                             "override" kind's extra
                                             role check already lives in
                                             ingest_event/2 from Prompt
                                             6 — do not duplicate it
                                             here, but do not remove the
                                             route-level requirement
                                             either, since a warden must
                                             still be authenticated to
                                             reach the endpoint at all)
  GET    /api/activations/:id/roll-call     warden ONLY — calls
                                             list_roll_call/2 with the
                                             CURRENT authenticated user,
                                             never a user_id from the
                                             request; there is no way to
                                             ask for another warden's list
                                             through this endpoint
  GET    /api/activations/:id/zones/:zone_id/roll-call
                                             admin, osh_officer — calls
                                             list_roll_call_for_zone/2
  POST   /api/activations/:id/people/:person_id/resolve-contradiction
                                             warden, admin, osh_officer
  GET    /api/activations/:id/dashboard/summary
  GET    /api/activations/:id/dashboard/departments
  GET    /api/activations/:id/dashboard/faculties
  GET    /api/activations/:id/dashboard/zones
  GET    /api/activations/:id/dashboard/unaccounted
                                             all five: admin, osh_officer,
                                             report_viewer

VERIFICATION
Boot the server against the dev database (reset to a known state: the
seeded admin, the full synthetic/roster people, no activations). Create
one user of each role for testing (admin already exists; create
osh_officer O1, warden W5 assigned to Zone 5, report_viewer R1). Using
curl throughout, tell me:

 1. mix compile clean; mix precommit passes; test count. (Controller
    tests, not just curl — the curl pass below is a human-readable
    smoke test on top of, not instead of, an ExUnit suite covering the
    same routes with SalvorionWeb.ConnCase.)
 2. A table: every route created, its RBAC entry, and a curl call per
    role showing 401 (no token), 403 (wrong role), and success (right
    role) — you do not need all three for every route, but every route
    needs at least one 403 demonstrated against a role that should not
    have it, and every "own scope" route (roll-call, device revoke)
    needs its cross-user case shown (W5 cannot fetch via a route meant
    to expose another warden's list, because no such route exists —
    confirm this by showing there is no user_id parameter accepted
    anywhere on GET /api/activations/:id/roll-call).
 3. Every ambiguous RBAC case from Task 4, listed explicitly with the
    reading chosen and why.
 4. One full curl-driven lifecycle: O1 starts a campus activation ->
    W5 signs in a real person via POST events with kind scanned ->
    W5 fetches GET roll-call and sees them accounted -> W5 resolves any
    contradiction if one exists (skip if none) -> O1 fetches
    GET dashboard/summary and GET dashboard/zones -> O1 closes the
    activation -> confirm a late field event (kind scanned,
    client_timestamp within the 5-minute window) still succeeds ->
    confirm one 10 minutes late does not.
 5. The file-upload route: a valid CSV via curl -F, and a non-CSV
    content-type rejected before it reaches the importer.
 6. Confirm GET /api/people/lookup for a nonexistent id_number returns
    404, not 200 with an empty body.
 7. Every file created or modified.

Stop after verification. Do not touch PowerSync config or start the
Reporting context.
```

---

## What to check yourself

1. **Item 2's "no route accepts a user_id for another warden's list" is the check that matters most.** Read the roll-call controller action yourself and confirm it takes the current user from the connection's auth assigns, not from any request parameter. A route that accepts an optional `user_id` "for testing" is exactly how this restriction quietly disappears.
2. **Read every case from item 3 and make the call yourself rather than accepting the default reading.** These are genuine gaps in how precisely Document 10 specifies things, not implementation questions, and the answer belongs in DECISIONS.md either way.
3. **Confirm the override role check from Prompt 6 was not duplicated or, worse, replaced by a weaker route-level check.** The route needs a role broad enough to reach the endpoint (any of admin/osh_officer/warden, since a warden's device is what most events come from); the actual override-specific restriction still has to be the one inside `ingest_event/2`.
4. **Try the roll-call endpoint as the seeded admin, not just as O1 or W5.** Prompt 6 made `admin` and `osh_officer` both trigger `{:error, :not_a_warden}` from `list_roll_call/2`. Confirm the route surfaces that correctly rather than 500ing on an unhandled case.
