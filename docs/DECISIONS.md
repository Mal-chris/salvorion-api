# Decisions and notes for upcoming work

Recorded during project scaffolding so they are not lost. None of these are
implemented yet.

## Guardian must use an asymmetric signing key (RS256 or ES256)

Do **not** use Guardian's default HS512 shared secret. PowerSync authenticates
clients by verifying their JWT against a JWKS endpoint that Phoenix will expose
at `/.well-known/jwks.json`. A symmetric key cannot be published as a JWKS
(publishing it would let anyone forge tokens), so tokens must be signed with an
RSA or EC private key and the matching public key served from that endpoint.
The PowerSync service config (`docker/powersync/powersync.yaml`) already points
`client_auth.jwks_uri` at that URL via `POWERSYNC_JWKS_URL`.

## Client offline outbox via PowerSync upload queue

The Flutter client uses PowerSync's upload queue as its offline outbox. The
client's PowerSync connector POSTs queued writes to this API, including a
client-generated `client_uuid` on each write for idempotency. The write
endpoints must therefore treat `client_uuid` as an idempotency key and return
success for replays of an already-applied write.

## Starting/closing an activation is OSH Officer only, not System Administrator

Per Document 10 (Security Design), section 1: the RBAC matrix lists "Start
an activation" and "Close an activation" as **OSH Officer only** — the
System Administrator column is blank for both rows. This is a different
shape from the Locations, Organisation and Settings permissions built in
Prompt 3, where OSH Officer and System Administrator are both permitted
("Manage assembly points, zones, areas", "Change system settings", etc.
are Yes/Yes). Whoever wires the RBAC route mapping for the Activations
routes (a later prompt) must not default to "same access as everything
else OSH Officer can do" — System Administrator does not get a pass on
starting or closing an activation, even though it does on almost every
other OSH-managed resource.

## Scaffolding choices (for reference)

- Generated with `mix phx.new . --app salvorion --module Salvorion --no-html --no-assets --no-live --binary-id`
  (Phoenix 1.8.13). API-only; UUID primary keys everywhere to match the
  domain model; Swoosh mailer kept for later email delivery.
- PowerSync uses **Postgres** for sync-bucket storage (a separate database,
  `powersync_storage`, on the same Postgres 16 server), so no MongoDB container.
- `docker/powersync/sync-config.yaml` is an empty Sync Streams (edition 3)
  placeholder; real streams are defined once the domain schema lands.
