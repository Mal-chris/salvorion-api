defmodule Salvorion.Repo.Migrations.CreateAreas do
  use Ecto.Migration

  def change do
    create table(:areas, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :building, :string
      add :floor, :string
      add :zone_id, references(:zones, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:areas, [:zone_id])
  end
end
