defmodule Salvorion.Organisation.Faculty do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "faculties" do
    field :name, :string
    field :code, :string

    has_many :departments, Salvorion.Organisation.Department
    has_many :programmes, Salvorion.Organisation.Programme

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(faculty, attrs) do
    faculty
    |> cast(attrs, [:name, :code])
    |> validate_required([:name, :code])
    |> unique_constraint(:code)
  end
end
