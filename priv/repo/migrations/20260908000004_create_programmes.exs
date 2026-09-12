defmodule Salvorion.Repo.Migrations.CreateProgrammes do
  use Ecto.Migration

  def change do
    create table(:programmes, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :code, :string, null: false
      add :faculty_id, references(:faculties, type: :binary_id, on_delete: :restrict), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:programmes, [:code])
    create index(:programmes, [:faculty_id])
  end
end
