defmodule Salvorion.Repo.Migrations.CreateActivationZones do
  use Ecto.Migration

  def change do
    create table(:activation_zones, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :activation_id, references(:activations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :zone_id, references(:zones, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:activation_zones, [:activation_id, :zone_id])
    create index(:activation_zones, [:zone_id])
  end
end
