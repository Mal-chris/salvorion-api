defmodule Salvorion.Activations.Activation do
  @moduledoc """
  A single drill or real emergency, from start to close. See
  FR-ACT-01 to FR-ACT-06 in the SRS (05) and the state diagram
  in Document 08, section 5:
  scheduled -> active -> closed -> reported.

  FR-ACT-05 (no two active activations overlapping in a zone) is enforced in
  the Activations context inside a transaction, not by a database constraint:
  zones live in the activation_zones join table and campus-wide activations
  have no rows there, so no single partial unique index can express the rule.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @types ~w(drill real)
  @statuses ~w(scheduled active closed reported)
  @scopes ~w(campus zones)

  schema "activations" do
    field :activation_type, :string
    field :status, :string, default: "scheduled"
    field :scope, :string, default: "campus"
    field :started_at, :utc_datetime_usec
    field :closed_at, :utc_datetime_usec

    belongs_to :started_by, Salvorion.Accounts.User
    belongs_to :closed_by, Salvorion.Accounts.User

    many_to_many :zones, Salvorion.Locations.Zone,
      join_through: "activation_zones",
      join_keys: [activation_id: :id, zone_id: :id]

    has_many :accountability_events, Salvorion.Accountability.AccountabilityEvent
    has_many :person_statuses, Salvorion.Accountability.PersonStatus
    has_many :expected_presences, Salvorion.Accountability.ExpectedPresence
    has_many :report_runs, Salvorion.Reporting.ReportRun

    timestamps(type: :utc_datetime_usec)
  end

  @doc "Changeset for starting a new activation. Type is fixed for its lifetime (FR-ACT-02)."
  def start_changeset(activation, attrs) do
    activation
    |> cast(attrs, [:activation_type, :scope, :started_by_id, :started_at])
    |> validate_required([:activation_type, :started_by_id, :started_at])
    |> validate_inclusion(:activation_type, unquote(@types))
    |> validate_inclusion(:scope, unquote(@scopes))
    |> put_change(:status, "active")
    |> foreign_key_constraint(:started_by_id)
  end

  @doc "Changeset for scheduling an activation in advance. It stays in `scheduled` until started."
  def schedule_changeset(activation, attrs) do
    activation
    |> cast(attrs, [:activation_type, :scope, :started_by_id, :started_at])
    |> validate_required([:activation_type, :started_by_id, :started_at])
    |> validate_inclusion(:activation_type, unquote(@types))
    |> validate_inclusion(:scope, unquote(@scopes))
    |> put_change(:status, "scheduled")
    |> foreign_key_constraint(:started_by_id)
  end

  @doc """
  Changeset for closing an activation. Does not permit changing activation_type.

  The status guard is an explicit check on the struct, not a `validate_inclusion`
  on `:status`: Ecto's validators only run for fields present in the changeset's
  changes, and `:status` is not cast here, so a validator would silently never run.
  """
  def close_changeset(%__MODULE__{} = activation, attrs) do
    activation
    |> cast(attrs, [:closed_by_id, :closed_at])
    |> validate_required([:closed_by_id, :closed_at])
    |> require_status("active", "activation must be active to close")
    |> put_change(:status, "closed")
    |> foreign_key_constraint(:closed_by_id)
  end

  @doc "Transition closed -> reported, once the report run has completed and deliveries were attempted."
  def mark_reported_changeset(%__MODULE__{} = activation) do
    activation
    |> change()
    |> require_status("closed", "activation must be closed before it can be marked reported")
    |> put_change(:status, "reported")
  end

  defp require_status(changeset, expected, message) do
    if changeset.data.status == expected do
      changeset
    else
      add_error(changeset, :status, message)
    end
  end

  def valid_statuses, do: @statuses
end
