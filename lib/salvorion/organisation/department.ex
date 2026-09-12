defmodule Salvorion.Organisation.Department do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "departments" do
    field :name, :string
    field :code, :string

    belongs_to :faculty, Salvorion.Organisation.Faculty
    has_many :people, Salvorion.Roster.Person, foreign_key: :primary_department_id

    many_to_many :areas, Salvorion.Locations.Area,
      join_through: "department_areas",
      join_keys: [department_id: :id, area_id: :id]

    many_to_many :secondary_people, Salvorion.Roster.Person,
      join_through: "person_departments",
      join_keys: [department_id: :id, person_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(department, attrs) do
    department
    |> cast(attrs, [:name, :code, :faculty_id])
    |> validate_required([:name, :code])
    |> unique_constraint(:code)
    |> foreign_key_constraint(:faculty_id)
  end
end
