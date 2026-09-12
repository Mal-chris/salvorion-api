defmodule Salvorion.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :email, :string, null: false
      add :password_hash, :string, null: false
      # admin | osh_officer | warden | report_viewer
      add :role, :string, null: false
      add :person_id, references(:people, type: :binary_id, on_delete: :nilify_all)
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:users, [:email])
    create index(:users, [:role])
  end
end
