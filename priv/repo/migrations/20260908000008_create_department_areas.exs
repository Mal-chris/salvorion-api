defmodule Salvorion.Repo.Migrations.CreateDepartmentAreas do
  use Ecto.Migration

  def change do
    create table(:department_areas, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :department_id, references(:departments, type: :binary_id, on_delete: :delete_all),
        null: false

      add :area_id, references(:areas, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:department_areas, [:department_id, :area_id])
    create index(:department_areas, [:area_id])
  end
end
