defmodule Salvorion.Locations.AssemblyPoint do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "assembly_points" do
    field :name, :string
    field :description, :string
    field :latitude, :decimal
    field :longitude, :decimal

    has_many :zones, Salvorion.Locations.Zone

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(assembly_point, attrs) do
    assembly_point
    |> cast(attrs, [:name, :description, :latitude, :longitude])
    |> validate_required([:name])
  end
end
