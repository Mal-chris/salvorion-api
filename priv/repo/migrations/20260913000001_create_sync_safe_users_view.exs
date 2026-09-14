defmodule Salvorion.Repo.Migrations.CreateSyncSafeUsersView do
  use Ecto.Migration

  @moduledoc """
  Defense in depth for PowerSync sync rules (Prompt 10, Task 3):
  `users.password_hash` must never be replicated to a client, even under a
  future misconfiguration of a sync rule/stream query. This view is a second,
  independent barrier — a query would need to be rewritten to select from
  `users` directly (or this view would need `password_hash` added to it,
  which is a visible, reviewable schema change) before the hash could ever
  reach the sync engine.

  See docs/DECISIONS.md ("PowerSync sync config (Prompt 10): the
  sync_safe_users view is not itself replicable") for whether the sync
  stream can actually select FROM this view (Postgres logical replication
  publications cannot contain views) or whether it is a documentation-only
  second barrier, confirmed empirically against the running service.
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
