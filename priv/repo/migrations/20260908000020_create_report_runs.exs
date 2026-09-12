defmodule Salvorion.Repo.Migrations.CreateReportRuns do
  use Ecto.Migration

  def change do
    create table(:report_runs, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :activation_id, references(:activations, type: :binary_id, on_delete: :restrict),
        null: false

      add :generated_at, :utc_datetime_usec
      add :pdf_path, :string
      # pending | generated | delivered | failed
      add :status, :string, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:report_runs, [:activation_id])
  end
end
