defmodule Salvorion.Repo.Migrations.CreateAssemblyPoints do
  use Ecto.Migration

  def change do
    create table(:assembly_points, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :description, :string
      add :latitude, :decimal
      add :longitude, :decimal

      timestamps(type: :utc_datetime_usec)
    end
  end
end
