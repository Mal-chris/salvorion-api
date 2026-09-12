defmodule Salvorion.Locations.Zone do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "zones" do
    field :number, :integer

    belongs_to :assembly_point, Salvorion.Locations.AssemblyPoint
    has_many :areas, Salvorion.Locations.Area
    has_many :warden_assignments, Salvorion.Accounts.WardenAssignment

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(zone, attrs) do
    zone
    |> cast(attrs, [:number, :assembly_point_id])
    |> validate_required([:number, :assembly_point_id])
    |> unique_constraint(:number)
    |> foreign_key_constraint(:assembly_point_id)
  end
end
