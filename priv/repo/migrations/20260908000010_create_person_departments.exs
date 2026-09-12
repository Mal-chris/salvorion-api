defmodule Salvorion.Repo.Migrations.CreatePersonDepartments do
  use Ecto.Migration

  def change do
    create table(:person_departments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all), null: false

      add :department_id, references(:departments, type: :binary_id, on_delete: :delete_all),
        null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:person_departments, [:person_id, :department_id])
    create index(:person_departments, [:department_id])
  end
end
