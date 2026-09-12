defmodule Salvorion.Repo.Migrations.CreateReportRecipients do
  use Ecto.Migration

  def change do
    create table(:report_recipients, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :email, :string, null: false
      add :role, :string
      add :active, :boolean, null: false, default: true

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:report_recipients, [:email])
  end
end
