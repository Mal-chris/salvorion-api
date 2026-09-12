defmodule Salvorion.Accountability.ExpectedPresence do
  @moduledoc """
  Computed once when an activation starts, from the roster and
  whichever student_accountability_rule setting is in effect
  (FR-ROS-05). A person with no row here is not counted toward
  "unaccounted" even if absent.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "expected_presences" do
    field :rule_applied, :string

    belongs_to :activation, Salvorion.Activations.Activation
    belongs_to :person, Salvorion.Roster.Person

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(expected_presence, attrs) do
    expected_presence
    |> cast(attrs, [:activation_id, :person_id, :rule_applied])
    |> validate_required([:activation_id, :person_id, :rule_applied])
    |> unique_constraint([:activation_id, :person_id])
    |> foreign_key_constraint(:activation_id)
    |> foreign_key_constraint(:person_id)
  end
end
