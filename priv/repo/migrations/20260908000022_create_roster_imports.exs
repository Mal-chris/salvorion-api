defmodule Salvorion.Repo.Migrations.CreateRosterImports do
  use Ecto.Migration

  def change do
    create table(:roster_imports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # file_import | scheduled_export | direct_database | synthetic
      add :provider, :string, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :completed_at, :utc_datetime_usec
      add :total_records, :integer
      add :error_count, :integer
      add :errors, :map

      timestamps(type: :utc_datetime_usec)
    end
  end
end
