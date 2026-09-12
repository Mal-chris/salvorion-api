defmodule Salvorion.Repo.Migrations.CreatePeople do
  use Ecto.Migration

  def change do
    create table(:people, primary_key: false) do
      add :id, :binary_id, primary_key: true
      # staff | student | visitor
      add :type, :string, null: false
      add :id_number, :string
      add :first_name, :string, null: false
      add :last_name, :string, null: false
      add :email, :string
      add :phone, :string

      add :primary_department_id,
          references(:departments, type: :binary_id, on_delete: :nilify_all)

      add :programme_id, references(:programmes, type: :binary_id, on_delete: :nilify_all)
      add :usual_area_id, references(:areas, type: :binary_id, on_delete: :nilify_all)
      # roster | synthetic | visitor_registration
      add :source, :string, null: false
      add :visitor_host, :string
      add :visitor_expires_at, :date

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:people, [:id_number], where: "id_number IS NOT NULL")
    create index(:people, [:type])
    create index(:people, [:primary_department_id])
    create index(:people, [:programme_id])
    create index(:people, [:visitor_expires_at], where: "type = 'visitor'")
  end
end
