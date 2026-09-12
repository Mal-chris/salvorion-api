defmodule Salvorion.Repo.Migrations.CreateExpectedPresences do
  use Ecto.Migration

  def change do
    create table(:expected_presences, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :activation_id, references(:activations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all), null: false
      add :rule_applied, :string, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:expected_presences, [:activation_id, :person_id])
  end
end
