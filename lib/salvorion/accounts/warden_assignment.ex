defmodule Salvorion.Accounts.WardenAssignment do
  @moduledoc """
  Assigns a user (in the warden role) responsibility for exactly
  one zone or one area, for a date range. See the check constraint
  `exactly_one_of_zone_or_area` in the migration.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "warden_assignments" do
    field :starts_at, :date
    field :ends_at, :date

    belongs_to :user, Salvorion.Accounts.User
    belongs_to :zone, Salvorion.Locations.Zone
    belongs_to :area, Salvorion.Locations.Area

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:user_id, :zone_id, :area_id, :starts_at, :ends_at])
    |> validate_required([:user_id, :starts_at])
    |> validate_exactly_one_scope()
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:zone_id)
    |> foreign_key_constraint(:area_id)
  end

  defp validate_exactly_one_scope(changeset) do
    zone_id = get_field(changeset, :zone_id)
    area_id = get_field(changeset, :area_id)

    case {zone_id, area_id} do
      {nil, nil} ->
        add_error(changeset, :zone_id, "must set either a zone or an area")

      {z, a} when not is_nil(z) and not is_nil(a) ->
        add_error(changeset, :zone_id, "must set only one of zone or area, not both")

      _ ->
        changeset
    end
  end
end
