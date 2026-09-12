defmodule Salvorion.Locations.DepartmentArea do
  @moduledoc """
  Join schema linking a Department to an Area. A department can occupy
  more than one area (e.g. spread across zones), and an area can house
  more than one department (e.g. the Steel Building).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "department_areas" do
    belongs_to :department, Salvorion.Organisation.Department
    belongs_to :area, Salvorion.Locations.Area

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(department_area, attrs) do
    department_area
    |> cast(attrs, [:department_id, :area_id])
    |> validate_required([:department_id, :area_id])
    |> unique_constraint([:department_id, :area_id])
    |> foreign_key_constraint(:department_id)
    |> foreign_key_constraint(:area_id)
  end
end
