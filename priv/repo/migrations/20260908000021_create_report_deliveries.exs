defmodule Salvorion.Repo.Migrations.CreateReportDeliveries do
  use Ecto.Migration

  def change do
    create table(:report_deliveries, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :report_run_id, references(:report_runs, type: :binary_id, on_delete: :delete_all),
        null: false

      add :report_recipient_id,
          references(:report_recipients, type: :binary_id, on_delete: :delete_all), null: false

      add :delivered_at, :utc_datetime_usec
      # pending | sent | failed
      add :delivery_status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:report_deliveries, [:report_run_id, :report_recipient_id])
    create index(:report_deliveries, [:report_recipient_id])
  end
end
