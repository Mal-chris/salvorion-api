# PowerSync sync-config verification tool (Prompt 10)

**Not part of the Salvorion application.** This is a throwaway verification
script that proves `docker/powersync/sync-config.yaml` behaves as documented,
using PowerSync's own official Node.js client SDK (`@powersync/node`)
against a real JWT from this project's own `POST /api/auth/login`. It is
not a preview of the Flutter client's eventual PowerSync integration
(Stage C, item 17) - it exists purely to answer "does the sync config
actually do what it says" without fabricating results.

Deliberately kept out of `lib/` (not application code) and `test/` (not an
automated test suite - it drives a real running `docker compose` stack and
a real Phoenix server, which the test suite must not depend on).

## Setup

```sh
cd tools/powersync-verify
npm install
```

## Usage

```sh
node verify.mjs <label> <access_token> <db_filename>
```

- `label` - a name printed in the script's own output, so you can tell runs
  apart (e.g. `O1`, `W5`).
- `access_token` - a real access token from `POST /api/auth/login`.
- `db_filename` - where to build the local SQLite mirror. Each run wipes
  this file first, so results reflect only the token/scope of *this* run.

Set `VERIFY_EXTRA=1` to also print the full `users` row, every
`person_statuses` row, and every `accountability_events` row (used to spot
specific rows/absences, not just counts).

Set `POWERSYNC_ENDPOINT` to override the default `http://127.0.0.1:8080`.

## What it checks

Prints a row count for every table any stream in `sync-config.yaml` can
populate. Compare counts across two tokens (e.g. an `osh_officer` token
that should see everything vs. a `warden` token scoped to one zone) to
confirm the sync rules are actually being enforced server-side, not merely
configured. See `docs/DECISIONS.md` and the Prompt 10 verification report
for the specific runs performed and their results.
