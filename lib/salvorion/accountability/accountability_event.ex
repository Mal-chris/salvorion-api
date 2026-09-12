defmodule Salvorion.Accountability.AccountabilityEvent do
  @moduledoc """
  An immutable, append-only record of a single sign-in, roll-call
  mark, or visitor registration. `client_uuid` is generated on the
  device at the moment of the action and is the idempotency key for
  sync retries (FR-SIGN-06): re-submitting the same client_uuid
  after a dropped connection must not create a duplicate row.

  Events are never updated or deleted by users. Current status per
  person per activation is derived into PersonStatus; this table is
  the permanent source of truth and the audit trail for "who marked
  what, when, from where".
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(scanned manual roll_call visitor_registered)
  @statuses ~w(present absent excused)

  schema "accountability_events" do
    field :client_uuid, Ecto.UUID
    field :kind, :string
    field :status, :string
    field :note, :string
    field :client_timestamp, :utc_datetime_usec
    field :server_timestamp, :utc_datetime_usec

    belongs_to :activation, Salvorion.Activations.Activation
    belongs_to :person, Salvorion.Roster.Person
    belongs_to :recorded_by, Salvorion.Accounts.User
    belongs_to :device, Salvorion.Accounts.Device
    belongs_to :assembly_point, Salvorion.Locations.AssemblyPoint
    belongs_to :area, Salvorion.Locations.Area

    timestamps(type: :utc_datetime_usec)
  end

  @doc """
  Events are created, never updated. `server_timestamp` is set by
  the server on ingest, never trusted from the client, so that
  ordering for the contradiction rule (FR-ROLL-05) cannot be
  manipulated by a device with a wrong clock.
  """
  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [
      :client_uuid,
      :activation_id,
      :person_id,
      :kind,
      :status,
      :recorded_by_id,
      :device_id,
      :assembly_point_id,
      :area_id,
      :note,
      :client_timestamp
    ])
    |> validate_required([
      :client_uuid,
      :activation_id,
      :person_id,
      :kind,
      :status,
      :recorded_by_id,
      :client_timestamp
    ])
    |> validate_inclusion(:kind, unquote(@kinds))
    |> validate_inclusion(:status, unquote(@statuses))
    |> put_change(:server_timestamp, DateTime.utc_now())
    |> unique_constraint(:client_uuid)
    |> foreign_key_constraint(:activation_id)
    |> foreign_key_constraint(:person_id)
    |> foreign_key_constraint(:recorded_by_id)
  end

  @doc "Whether this event kind counts as authoritative over a roll_call mark (FR-ROLL-05)."
  def outranks_roll_call?(%__MODULE__{kind: "scanned"}), do: true
  def outranks_roll_call?(_), do: false
end
