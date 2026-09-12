defmodule Salvorion.Repo.Migrations.CreateFaculties do
  use Ecto.Migration

  def change do
    create table(:faculties, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :code, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:faculties, [:code])
  end
end
