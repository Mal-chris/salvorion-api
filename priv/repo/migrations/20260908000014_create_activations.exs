defmodule Salvorion.Repo.Migrations.CreateActivations do
  use Ecto.Migration

  def change do
    create table(:activations, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # drill | real
      add :activation_type, :string, null: false
      # scheduled | active | closed | reported
      add :status, :string, null: false, default: "scheduled"
      # campus | zones
      add :scope, :string, null: false, default: "campus"
      add :started_by_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :closed_by_id, references(:users, type: :binary_id, on_delete: :restrict)
      add :started_at, :utc_datetime_usec, null: false
      add :closed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:activations, [:status])
    create index(:activations, [:activation_type])
  end
end
