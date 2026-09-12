defmodule Salvorion.Roster.PersonDepartment do
  @moduledoc """
  Secondary departmental membership for a person, beyond their
  primary_department_id on Person. Used for joint appointments
  and multi-unit buildings such as the Steel Building.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "person_departments" do
    belongs_to :person, Salvorion.Roster.Person
    belongs_to :department, Salvorion.Organisation.Department

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(person_department, attrs) do
    person_department
    |> cast(attrs, [:person_id, :department_id])
    |> validate_required([:person_id, :department_id])
    |> unique_constraint([:person_id, :department_id])
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:department_id)
  end
end
