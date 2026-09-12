defmodule Salvorion.Activations.ActivationZone do
  @moduledoc """
  Join schema scoping an Activation to specific zones, used only
  when scope == "zones". A campus-wide activation has no rows
  here and implicitly includes every zone.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "activation_zones" do
    belongs_to :activation, Salvorion.Activations.Activation
    belongs_to :zone, Salvorion.Locations.Zone

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(activation_zone, attrs) do
    activation_zone
    |> cast(attrs, [:activation_id, :zone_id])
    |> validate_required([:activation_id, :zone_id])
    |> unique_constraint([:activation_id, :zone_id])
    |> foreign_key_constraint(:activation_id)
    |> foreign_key_constraint(:zone_id)
  end
end
