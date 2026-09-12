defmodule Salvorion.Repo.Migrations.CreateWardenAssignments do
  use Ecto.Migration

  def change do
    create table(:warden_assignments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :zone_id, references(:zones, type: :binary_id, on_delete: :delete_all)
      add :area_id, references(:areas, type: :binary_id, on_delete: :delete_all)
      add :starts_at, :date, null: false
      add :ends_at, :date

      timestamps(type: :utc_datetime_usec)
    end

    create index(:warden_assignments, [:user_id])
    create index(:warden_assignments, [:zone_id])
    create index(:warden_assignments, [:area_id])

    create constraint(:warden_assignments, :exactly_one_of_zone_or_area,
             check: "(zone_id IS NOT NULL)::int + (area_id IS NOT NULL)::int = 1"
           )
  end
end
