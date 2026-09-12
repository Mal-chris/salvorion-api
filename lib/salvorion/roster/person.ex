defmodule Salvorion.Roster.Person do
  @moduledoc """
  A staff member, student, or visitor. `source` tracks provenance
  (roster import, synthetic generation, or on-the-spot visitor
  registration) without affecting how the person is treated
  elsewhere in the system.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(staff student visitor)
  @sources ~w(roster synthetic visitor_registration)

  schema "people" do
    field :type, :string
    field :id_number, :string
    field :first_name, :string
    field :last_name, :string
    field :email, :string
    field :phone, :string
    field :source, :string
    field :visitor_host, :string
    field :visitor_expires_at, :date

    belongs_to :primary_department, Salvorion.Organisation.Department
    belongs_to :programme, Salvorion.Organisation.Programme
    belongs_to :usual_area, Salvorion.Locations.Area

    has_one :user, Salvorion.Accounts.User

    many_to_many :departments, Salvorion.Organisation.Department,
      join_through: "person_departments",
      join_keys: [person_id: :id, department_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(person, attrs) do
    person
    |> cast(attrs, [
      :type,
      :id_number,
      :first_name,
      :last_name,
      :email,
      :phone,
      :primary_department_id,
      :programme_id,
      :usual_area_id,
      :source,
      :visitor_host,
      :visitor_expires_at
    ])
    |> validate_required([:type, :first_name, :last_name, :source])
    |> validate_inclusion(:type, unquote(@types))
    |> validate_inclusion(:source, unquote(@sources))
    |> validate_id_number_presence()
    |> unique_constraint(:id_number)
    |> foreign_key_constraint(:primary_department_id)
    |> foreign_key_constraint(:programme_id)
    |> foreign_key_constraint(:usual_area_id)
  end

  # Staff and students must have an ID number; visitors need not.
  defp validate_id_number_presence(changeset) do
    case get_field(changeset, :type) do
      "visitor" -> changeset
      _ -> validate_required(changeset, [:id_number])
    end
  end
end
