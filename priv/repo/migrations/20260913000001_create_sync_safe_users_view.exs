defmodule Salvorion.Repo.Migrations.CreateSyncSafeUsersView do
  use Ecto.Migration

  @moduledoc """
  Defense in depth for PowerSync Sync Streams (Prompt 10, Task 3):
  `users.password_hash` must never be replicated to a client, even under a
  future misconfiguration of a sync stream query. This view is a second,
  independent barrier — a query would need to be rewritten to select from
  `users` directly (or this view would need `password_hash` added to it,
  which is a visible, reviewable schema change) before the hash could ever
  reach the sync engine.

  See docs/DECISIONS.md ("PowerSync sync config (Prompt 10): `sync_safe_users`
  cannot be the sync source — a Postgres, not PowerSync, limitation") — this
  was settled, not left open: Postgres logical replication publications
  cannot contain views (`CREATE PUBLICATION ... FOR ALL TABLES` only ever
  includes base tables), confirmed empirically against the running service,
  so the sync stream queries `users` directly rather than this view. This
  view stays in the schema purely as the second, reviewable barrier described
  above — no sync stream selects from it.
  """

  def up do
    execute """
    CREATE VIEW sync_safe_users AS
      SELECT id, email, role, active, inserted_at, updated_at
      FROM users;
    """
  end

  def down do
    execute "DROP VIEW sync_safe_users;"
  end
end
