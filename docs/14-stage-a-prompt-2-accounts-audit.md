# Stage A — Prompt 2: Domain Schema Import, Accounts, Audit

**Document:** 14 of the project record
**Corresponds to:** Technical Foundation (03), Stage A, items 3–5; Security Design (10), section 7
**Environment:** WSL2 Ubuntu, inside `~/salvorion` (the `salvorion-api` repository)
**Prepared:** 11 September 2026

---

## Before you start: get the corrected Ecto package into WSL2

The migrations and schemas were written outside your machine and audited/fixed afterward (Document 13). They exist on your machine only if you've downloaded `salvorion-ecto-schema.zip`. Get it into Ubuntu now:

1. Download `salvorion-ecto-schema.zip` if you haven't already (it should be sitting in your Windows Downloads folder).
2. From your Ubuntu terminal, copy it across the WSL2/Windows boundary and unzip it into a staging folder, **not** directly into `~/salvorion`, since Claude Code needs to merge it against files that already exist (like `lib/salvorion/repo.ex` and `mix.exs`), not overwrite blindly:

```
mkdir -p ~/staging
cp /mnt/c/Users/malch/Downloads/salvorion-ecto-schema.zip ~/staging/
cd ~/staging
unzip salvorion-ecto-schema.zip
ls salvorion/priv/repo/migrations
ls salvorion/lib/salvorion
```

You should see 24 migration files and nine context folders (`accountability`, `accounts`, `activations`, `audit`, `locations`, `organisation`, `reporting`, `roster`, `settings`). If either `ls` comes back empty, stop and tell me before starting Claude Code.

---

## The prompt

```
This is the second step in building Salvorion. Prompt 1 (already complete)
scaffolded this Phoenix project and its Docker Compose stack. This prompt
imports the audited domain schema and builds the two contexts that must
exist before anything else: Accounts and Audit.

REFERENCE MATERIAL
A staged copy of the domain migrations and Ecto schemas is at
~/staging/salvorion/. Its priv/repo/migrations/ (24 files) and
lib/salvorion/ (nine context folders: accountability, accounts,
activations, audit, locations, organisation, reporting, roster, settings)
are the authoritative domain model. Do not redesign it. Where a schema
file already exists in both the staging copy and this project (this
project currently has no domain schemas of its own, only the generator's
defaults — application.ex, repo.ex, mailer.ex, etc. — so there should be
no real conflicts), the staging copy wins.

TASK 1: Merge the domain schema into this project
- Copy all 24 files from ~/staging/salvorion/priv/repo/migrations/ into
  this project's priv/repo/migrations/, preserving their timestamps in
  the filenames (do not regenerate timestamps — the migration order
  matters and is encoded in those filenames).
- Copy all nine context folders from ~/staging/salvorion/lib/salvorion/
  into this project's lib/salvorion/.
- Add any missing dependencies these schemas require to mix.exs. At
  minimum: argon2_elixir (the accounts/user.ex schema calls
  Argon2.hash_pwd_salt). Check every schema file for other library
  calls (e.g. anything using Ecto.UUID, Ecto.Enum) and confirm the
  underlying libraries are present; Ecto itself already covers most of
  this.
- Run `mix deps.get`, then `mix ecto.create` (the database does not
  exist yet — Docker Compose provisions Postgres but does not run
  Ecto's own database/schema setup), then `mix ecto.migrate`.
- Run `mix compile` and resolve any compilation errors. Do not silently
  work around a broken reference by deleting or stubbing a schema field
  — if something doesn't compile, tell me what and why before deciding
  how to fix it.

TASK 2: The Accounts context — public API
Create lib/salvorion/accounts.ex (the context module; the schemas already
exist in lib/salvorion/accounts/) exposing at minimum:
- register_user/1 — creates a User via User.changeset/2, given a role,
  email, password, and optional person_id. Returns {:ok, user} or
  {:error, changeset}.
- authenticate_user/2 — given email and password, verifies the argon2
  hash and returns {:ok, user} or {:error, :invalid_credentials}. Do not
  leak whether the email exists (same error for "no such user" and
  "wrong password").
- get_user!/1, list_users/0, update_user_role/2, deactivate_user/1
  (sets active: false — do not delete user records; see Document 10,
  section 2, on data classification).
- register_device/2 and revoke_device/1 (sets devices.revoked_at —
  see Document 13, finding 2.5; this field already exists in the
  migration you just imported).
- assign_warden/3 (user_id, zone_id_or_area_id, date range) — creates a
  WardenAssignment; validate exactly one of zone/area is given, matching
  the schema's own validation, so the error surfaces before hitting the
  database constraint.

TASK 3: Guardian, with an asymmetric signing key
This is the part most likely to be gotten wrong by default, so follow
this precisely rather than using Guardian's typical HS256 tutorial setup.
PowerSync (already configured in docker-compose.yml with
PS_JWKS_URL pointing at http://host.docker.internal:4000/.well-known/jwks.json)
verifies tokens against a published JWKS, which requires an ASYMMETRIC
key pair (RS256). A symmetric secret cannot be published as a JWKS.

- Generate an RSA key pair for development (e.g. via `openssl genrsa` and
  `openssl rsa -pubout`), store the private key path in runtime
  configuration (an environment variable pointing at a file, not the key
  material itself committed to git — add the key files to .gitignore).
- Configure a Guardian module (Salvorion.Accounts.Guardian) with
  allowed_algos: ["RS256"], the private key loaded at startup, subject
  built from the User's id, and claims including "role" (from
  User.role) so the authorization plug (Task 4) can check role without
  a database round-trip on every request.
- Implement token issuance: access tokens expire in 15 minutes, refresh
  tokens in 30 days (Document 10, section 4). Expose these through the
  Accounts context, e.g. Accounts.issue_tokens(user).
- Implement a JWKS endpoint at GET /.well-known/jwks.json, publicly
  accessible (no auth required — that's the point of a JWKS endpoint),
  returning the public key in JWK format with a "keys" array containing
  one entry, with a stable "kid" (key ID) that matches the "kid" you put
  in issued tokens' headers. Use the `jose` library (already a Guardian
  dependency — do not add a second JWT/JWK library) to derive the JWK
  from the RSA public key; do not hand-roll JWK encoding.
- Add a controller action (e.g. POST /api/auth/login) that calls
  authenticate_user/2 and, on success, returns both tokens as JSON; on
  failure, returns 401 with no detail beyond "invalid credentials".

TASK 4: Authorization plug, matching the RBAC matrix exactly
- Implement a plug that: verifies the Guardian token, loads the role
  claim, and rejects the request (401) if the token is missing/invalid,
  or (403) if the user's role is not permitted for that route. Also
  check the token's associated device (if a device_id claim is present)
  against Device.revoked_at, rejecting with 401 if revoked (Document 10,
  section 4).
- Build this as data, not a long if/else chain: a route-to-allowed-roles
  mapping the router can declare per route or per pipeline, so the
  mapping can be read at a glance and checked against Document 10,
  section 1's table directly. I will check the two match after this
  prompt completes; get it as close as you can from the SRS role names
  (System Administrator = admin, OSH Officer = osh_officer, Safety
  Warden = warden, Report Viewer = report_viewer).
- You do not need every route from that table to exist yet (most
  contexts haven't been built). Wire the plug and the mapping mechanism
  now; apply it to the auth routes that do exist (login is public,
  everything else in this prompt requires a valid token).

TASK 5: The Audit context
- Create lib/salvorion/audit.ex exposing record/1, taking a map with
  actor_user_id (nullable), action, entity_type, entity_id, before,
  after — and writing an AuditLog row. This must be the ONLY code path
  that writes to audit_logs; do not expose an update or delete function
  on this context, matching FR-AUD-02 and the audit_log.ex schema's own
  moduledoc, which already documents this rule.
- Call Audit.record/1 from every Accounts function in Task 2 that
  creates, updates, or deactivates something (register_user,
  update_user_role, deactivate_user, register_device, revoke_device,
  assign_warden). Use nil for actor_user_id only where there is
  genuinely no acting user (there shouldn't be any such case in this
  context — every Accounts action here is performed by an authenticated
  user).
- Add list_audit_logs/1 (filterable by entity_type, actor_user_id, date
  range) for the future admin screen. Do not add a route for it yet —
  the RBAC plug from Task 4 needs the admin role wired to something to
  protect, and there's no admin UI to call it from yet either. Just
  have the context function ready.

TASK 6: Seed an initial administrator
- Add to priv/repo/seeds.exs: create one System Administrator user (a
  fixed development email/password — print the password to the console
  when the seed runs, do not hardcode it silently) via
  Accounts.register_user/1, so there's a way to log in and test.

VERIFICATION
After completing all tasks, tell me explicitly:
1. Output of `mix ecto.migrate` (all 24 migrations, listed by name,
   applied with no errors).
2. Output of `mix compile` with zero warnings introduced by this
   prompt's code (pre-existing generator warnings, if any, are fine —
   call out anything NEW).
3. The exact curl command to hit POST /api/auth/login with the seeded
   admin's credentials, and its response (tokens should be present;
   redact nothing, this is local development data).
4. The exact curl command to hit GET /.well-known/jwks.json, and its
   full response.
5. Confirmation that the "kid" in a decoded access token's header
   matches the "kid" in the JWKS response — show me both values
   side by side.
6. A list of every file you created or modified, grouped by task.
7. Anything from Document 10's RBAC matrix (section 1) that Task 4's
   route-to-role mapping cannot yet express given what's built so far,
   so I know what to check once more contexts exist.

Stop after verification and wait for the next prompt. Do not start on
the Organisation, Locations, or Roster contexts yet.
```

---

## What to check yourself, before considering this prompt done

1. **Actually decode a JWT it issues.** Log in via curl, take the access token, and paste it into jwt.io (or run it through `mix guardian.decode` if such a task exists, or just base64-decode the header/payload segments yourself: `echo '<header-segment>' | base64 -d`). Confirm the algorithm listed is `RS256`, not `HS256`. This is the single most important check in this entire prompt, since an HS256 token will authenticate fine against your own API but will be silently rejected by PowerSync, and you will not find out until Stage C, far from where the mistake was made.
2. **Hit the JWKS endpoint with no auth header at all** and confirm it responds (it must be public). Then hit it with a garbage `Authorization` header and confirm it still responds the same way, unaffected by the auth plug.
3. **Confirm the private key file is not in git.** `git status` after this prompt should not show your RSA private key. Check `.gitignore` was actually updated, don't assume Claude Code remembered.
4. **Try logging in with a wrong password**, and separately with a nonexistent email, and confirm both return the identical error message and status code. A different error for each is a small information leak (confirms which emails have accounts) worth catching now rather than carrying forward as a habit into every other auth-adjacent endpoint later.
5. **Read the route-to-role mapping Task 4 produced and compare it to Document 10, section 1, yourself**, line by line, rather than trusting item 7 of the verification report alone. The audit exists precisely because self-reported consistency claims have been wrong before in this project.
6. **Confirm `mix ecto.rollback` works** for at least the most recent migration, then `mix ecto.migrate` again to bring it back. This is a cheap, fast way to catch a migration that looks fine going up but was never actually tested coming down (relevant here since Document 13, finding 2.11, specifically flagged one migration's broken `down`).

Once all six of these check out, you're ready for Prompt 3: the Organisation and Locations contexts, seeded with the actual OSH Emergency Assembly Point Guide data (Document 03's "synthetic roster provider and OSH assembly point seed data," Stage A item 4).
