# Stage A — Prompt 1: Repository, Phoenix Scaffold, Docker Compose

**Document:** 12 of the project record
**Corresponds to:** Technical Foundation (03), Stage A, item 1-2
**Environment:** Backend work happens in WSL2 (Ubuntu); Flutter work happens natively on Windows. This prompt covers the backend half only.
**Prepared:** 8 September 2026, revised 11 September 2026 after the consistency audit (Document 13)

---

## How to use this

Open your WSL2 Ubuntu terminal, `cd ~/salvorion` (the folder you created inside Ubuntu; the Flutter client will live separately at `C:\Users\malch\salvorion` on Windows), and start Claude Code there (`claude` from the terminal, or via the VS Code extension with a WSL window open on that folder). Paste the prompt below as your first message. After Claude Code finishes, run the verification steps in the section after the prompt before moving to Prompt 2.

---

## The prompt

```
I'm building Salvorion, an emergency assembly accountability system for a
university. This is the first step: scaffold the backend repository and
local development environment. Do not build any business logic yet, this
is purely project setup.

CONTEXT
- Backend: Elixir / Phoenix, using Ecto against PostgreSQL
- Background jobs: Oban (Postgres-backed, no Redis)
- Real-time: Phoenix Channels / PubSub (built in, no external broker)
- Client sync: PowerSync (a separate service, connects to Postgres via
  logical replication) — not built by you in this step, just provisioned
  in Docker Compose so it's available later
- PDF rendering: Gotenberg (a separate containerised service), also just
  provisioned, not integrated yet
- This project's domain model, migrations and Ecto schemas already exist
  in a reference package I'll provide separately — this prompt is ONLY
  about project scaffolding, tooling, and Docker Compose. Do not invent
  your own domain schema.
- Repository layout: this is the BACKEND repository only, named
  `salvorion-api`. The Flutter client is a separate repository
  (`salvorion-client`) that lives on a different filesystem; never
  create client code here. Project documentation lives in this
  repository under `docs/` (create the folder, leave it empty for now).

TASK 1: Create the Phoenix project
- We are already inside the empty directory `~/salvorion`. Generate the
  Phoenix project INTO this directory (not a nested subfolder) with:
    mix phx.new . --app salvorion --module Salvorion --no-html --no-assets --no-live --binary-id
  Rationale for each flag: standard (non-umbrella) app; API-only, since
  this backend serves JSON and WebSocket traffic only, never server-
  rendered HTML; `--binary-id` because every table in the domain model
  uses UUID primary keys and generators must match. Keep the default
  mailer (Swoosh) — email delivery is needed later.
- If `mix phx.new .` is not supported by the installed generator
  version, generate into a temporary folder and move the contents up,
  so the project root is `~/salvorion`.
- Confirm the generated project compiles and `mix phx.server` starts
  without error before doing anything else.

TASK 2: Add and configure core dependencies in mix.exs
- Oban (background jobs, Postgres-backed)
- Guardian (JWT authentication)
- argon2_elixir (password hashing)
- CORS handling suitable for a Flutter web client calling from a
  different origin during development (e.g. the `cors_plug` package)
- open_api_spex (or an equivalent actively-maintained library) for
  generating an OpenAPI specification from route/schema definitions
- Do not run any of these yet beyond adding them to mix.exs and running
  `mix deps.get` — actual configuration of each is a later prompt.

TASK 3: Docker Compose for local development
Create a docker-compose.yml at the project root with these services:
- `postgres`: PostgreSQL 16, with a named volume for data persistence,
  exposing the standard port, with a database name, user and password
  suitable for local development (not production secrets).
  REQUIRED for PowerSync: start Postgres with logical replication
  enabled (`command: postgres -c wal_level=logical`), and add an init
  SQL script (mounted into /docker-entrypoint-initdb.d/) that creates
  a `powersync` role with REPLICATION and LOGIN, and a publication
  named `powersync` FOR ALL TABLES. Without wal_level=logical the
  PowerSync container will start but never replicate.
- `powersync`: using PowerSync's published self-hosted Docker image.
  Consult PowerSync's current self-hosting documentation (do not guess)
  for: the config file format, the Postgres source connection (use the
  `powersync` role above), and the bucket-storage backend. Prefer
  Postgres as the bucket-storage backend if the version you pull
  supports it, so no MongoDB container is needed; if it does not, add
  a `mongo` service and say so explicitly in your summary. Include a
  clearly commented placeholder sync-rules file (a minimal valid file
  that syncs nothing), since real sync rules come in a later prompt.
  Goal for this step: the service starts, connects to Postgres, and
  its health endpoint responds.
- `gotenberg`: using Gotenberg's published Docker image, exposed on a
  local port, no further configuration needed at this stage.
Add a `.env.example` file documenting every environment variable the
compose file expects, with placeholder (non-secret) values.

TASK 4: Project-level tooling
- Add a `.gitignore` appropriate for a Phoenix project (standard
  `mix phx.new` output, plus `.env`, plus editor/OS cruft for both
  Windows and WSL development).
- Add a `.formatter.exs` if not already present from the generator.
- Add a `.tool-versions` or equivalent file recording the exact Erlang
  and Elixir versions in use, so this matches what's installed via mise
  (Erlang/OTP 29, Elixir 1.20.4-otp-29 — confirm these are compatible
  with the Phoenix version generated; flag clearly if not).
- Add a minimal README.md explaining: what this project is (one
  paragraph), how to start local services (`docker compose up`), how to
  run the Phoenix server (`mix phx.server`), and where the Flutter
  client lives (a sibling directory on the Windows side, not inside
  this repository — note this explicitly since it's an unusual split).

TASK 5: GitHub Actions CI skeleton
- Add a basic `.github/workflows/ci.yml` that, on every push: checks
  out the code, sets up Erlang/Elixir matching the versions above,
  installs dependencies, runs `mix format --check-formatted`, and runs
  `mix test` (even though there are no real tests yet — this should run
  and pass against the generator's default test).
- Do not add deployment steps yet.

NOTES FOR LATER PROMPTS (do not act on these now; record them in
docs/DECISIONS.md so they are not lost):
- Guardian must be configured with an asymmetric signing key (RS256 or
  ES256), not its default HS512 secret, because PowerSync authenticates
  clients against a JWKS endpoint (`/.well-known/jwks.json`) that
  Phoenix will expose. Symmetric keys cannot be published as a JWKS.
- The Flutter client will use PowerSync's upload queue as its offline
  outbox; the client's PowerSync connector POSTs queued writes to this
  API with a client-generated `client_uuid` for idempotency.

VERIFICATION
After completing all tasks, tell me explicitly:
1. The exact command you ran to generate the Phoenix project, and its
   full output.
2. That `mix phx.server` starts successfully.
3. That `docker compose up` starts all three services without error
   (postgres, powersync, gotenberg), and how to check each one is
   actually reachable (e.g. a curl or psql command per service).
4. Any dependency in Task 2 that failed to install or had a version
   conflict, with the exact error.
5. A tree view of the final project structure.

Do not proceed past this point or start on domain logic. Stop after
verification and wait for the next prompt.
```

---

## What to check yourself, before considering this prompt done

Claude Code's own VERIFICATION report is a starting point, not something to accept blindly. Confirm these yourself, since they're cheap to check and expensive to discover wrong later:

1. **Run `mix phx.server` yourself**, don't just read that Claude Code says it worked. You should see the same "Running SalvorionWeb.Endpoint" message you saw with the `hello` throwaway project.
2. **Run `docker compose up` yourself** and watch the logs for all three services (four, if MongoDB was needed). PowerSync and Gotenberg are less common than Postgres, so actually confirm their containers report a healthy/running state, not just "no red text scrolled by." Then confirm logical replication is on: `docker compose exec postgres psql -U <user> -d <db> -c "SHOW wal_level;"` must print `logical`.
3. **Check the `.env.example` file makes sense to you.** If you don't recognise a variable or it looks like a guess rather than something the actual PowerSync or Gotenberg image documentation calls for, ask Claude Code to justify it or look it up, since Docker images sometimes expect very specific variable names.
4. **Open `mix.exs` and skim the dependency versions added.** You don't need to understand each one deeply yet, just confirm nothing looks wildly outdated or suspiciously unofficial (a package with very few downloads for something as common as JWT auth would be a red flag worth asking about).
5. **Confirm the CI workflow file references your actual Erlang/Elixir versions**, not a default it might have guessed, since a mismatch here would make CI fail for reasons unrelated to your actual code.

Once all five of these check out, you're ready for Prompt 2 (the Ecto schema and migrations, using the reference package from Document 06, plus the Accounts/Auth context).
