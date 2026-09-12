defmodule Salvorion.Repo.Migrations.CreateAccountabilityEvents do
  use Ecto.Migration

  def change do
    create table(:accountability_events, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :client_uuid, :binary_id, null: false

      add :activation_id, references(:activations, type: :binary_id, on_delete: :restrict),
        null: false

      add :person_id, references(:people, type: :binary_id, on_delete: :restrict), null: false
      # scanned | manual | roll_call | visitor_registered
      add :kind, :string, null: false
      # present | absent | excused
      add :status, :string, null: false
      add :recorded_by_id, references(:users, type: :binary_id, on_delete: :restrict), null: false
      add :device_id, references(:devices, type: :binary_id, on_delete: :nilify_all)

      add :assembly_point_id,
          references(:assembly_points, type: :binary_id, on_delete: :nilify_all)

      add :area_id, references(:areas, type: :binary_id, on_delete: :nilify_all)
      add :note, :string
      add :client_timestamp, :utc_datetime_usec, null: false
      add :server_timestamp, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:accountability_events, [:client_uuid])
    create index(:accountability_events, [:activation_id, :person_id])
    create index(:accountability_events, [:kind])
  end
end
