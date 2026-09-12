defmodule Salvorion.Repo.Migrations.CreateAuditLogs do
  use Ecto.Migration

  def change do
    create table(:audit_logs, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :actor_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :action, :string, null: false
      add :entity_type, :string, null: false
      add :entity_id, :binary_id
      add :before, :map
      add :after, :map

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:audit_logs, [:entity_type, :entity_id])
    create index(:audit_logs, [:actor_user_id])
  end
end
