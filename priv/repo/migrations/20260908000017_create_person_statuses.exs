defmodule Salvorion.Repo.Migrations.CreatePersonStatuses do
  use Ecto.Migration

  def change do
    create table(:person_statuses, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :activation_id, references(:activations, type: :binary_id, on_delete: :delete_all),
        null: false

      add :person_id, references(:people, type: :binary_id, on_delete: :delete_all), null: false
      # present | absent | excused | unaccounted
      add :status, :string, null: false

      add :source_event_id,
          references(:accountability_events, type: :binary_id, on_delete: :nilify_all)

      add :contradicting_event_id,
          references(:accountability_events, type: :binary_id, on_delete: :nilify_all)

      add :contradiction_resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:person_statuses, [:activation_id, :person_id])

    create index(:person_statuses, [:activation_id, :contradicting_event_id],
             where: "contradicting_event_id IS NOT NULL AND contradiction_resolved_at IS NULL",
             name: :person_statuses_open_contradictions_index
           )
  end
end
