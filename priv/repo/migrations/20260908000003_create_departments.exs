defmodule Salvorion.Repo.Migrations.CreateDepartments do
  use Ecto.Migration

  def change do
    create table(:departments, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :code, :string, null: false
      add :faculty_id, references(:faculties, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:departments, [:code])
    create index(:departments, [:faculty_id])
  end
end
