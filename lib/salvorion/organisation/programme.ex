defmodule Salvorion.Organisation.Programme do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "programmes" do
    field :name, :string
    field :code, :string

    belongs_to :faculty, Salvorion.Organisation.Faculty
    has_many :people, Salvorion.Roster.Person

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(programme, attrs) do
    programme
    |> cast(attrs, [:name, :code, :faculty_id])
    |> validate_required([:name, :code, :faculty_id])
    |> unique_constraint(:code)
    |> foreign_key_constraint(:faculty_id)
  end
end
