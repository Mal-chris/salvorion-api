# Salvorion API

Salvorion is an emergency assembly accountability system for a university:
during an evacuation it tracks who has reached which assembly point, who is
still unaccounted for, and produces the reports incident controllers need. This
repository is the backend only: an Elixir/Phoenix JSON + WebSocket API backed
by PostgreSQL, with Oban for background jobs, Phoenix Channels/PubSub for
real-time updates, PowerSync for offline-first client sync, and Gotenberg for
PDF rendering.

## Requirements

- Erlang/OTP and Elixir as pinned in `.tool-versions` (install via `mise install`)
- Docker with Compose v2+

## Local services

```sh
cp .env.example .env   # optional; defaults work as-is
docker compose up -d
docker compose ps      # postgres and powersync report "healthy"
```

| Service   | Host port | Check                                                      |
|-----------|-----------|------------------------------------------------------------|
| postgres  | 5432      | `psql postgresql://postgres:postgres@localhost:5432/salvorion_dev -c 'select 1'` |
| powersync | 8080      | `curl -i http://localhost:8080/probes/liveness`            |
| gotenberg | 3000      | `curl -i http://localhost:3000/health`                     |

Postgres runs with `wal_level=logical`; a one-time init script creates the
`powersync` replication role, the `powersync` publication, and the
`powersync_storage` database. To re-run it, wipe the volume:
`docker compose down -v`.

## Running the API

```sh
mix setup        # deps.get + ecto.create + migrate + seeds
mix phx.server   # http://localhost:4000
```

Run `mix test` for the test suite and `mix precommit` before pushing.

## Repository layout

- `lib/salvorion` – domain/contexts
- `lib/salvorion_web` – API endpoint, router, controllers, channels
- `docker/` – service configuration mounted by `docker-compose.yml`
- `docs/` – project documentation and decision records

## Where is the client?

The Flutter client is **not** in this repository. It lives in a separate repo,
`salvorion-client`, kept as a sibling directory on the Windows filesystem
(the backend is developed under WSL). Nothing under this repo should reference
client code, and no client code should be created here.
