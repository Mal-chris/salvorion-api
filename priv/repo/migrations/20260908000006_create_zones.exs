defmodule Salvorion.Repo.Migrations.CreateZones do
  use Ecto.Migration

  def change do
    create table(:zones, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :number, :integer, null: false

      add :assembly_point_id,
          references(:assembly_points, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:zones, [:number])
    create index(:zones, [:assembly_point_id])
  end
end
