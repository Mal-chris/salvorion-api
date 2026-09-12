defmodule Salvorion.Locations.Area do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "areas" do
    field :name, :string
    field :building, :string
    field :floor, :string

    belongs_to :zone, Salvorion.Locations.Zone
    has_many :warden_assignments, Salvorion.Accounts.WardenAssignment

    many_to_many :departments, Salvorion.Organisation.Department,
      join_through: "department_areas",
      join_keys: [area_id: :id, department_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(area, attrs) do
    area
    |> cast(attrs, [:name, :building, :floor, :zone_id])
    |> validate_required([:name, :zone_id])
    |> foreign_key_constraint(:zone_id)
  end
end
