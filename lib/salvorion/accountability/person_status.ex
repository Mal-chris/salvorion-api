defmodule Salvorion.Accountability.PersonStatus do
  @moduledoc """
  Derived, upserted view of a person's current status within one
  activation. Not a source of truth; recomputed from
  AccountabilityEvent whenever a relevant event is ingested. Exists
  so dashboard queries do not need to scan full event history.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(present absent excused unaccounted)

  schema "person_statuses" do
    field :status, :string
    field :contradiction_resolved_at, :utc_datetime_usec

    belongs_to :activation, Salvorion.Activations.Activation
    belongs_to :person, Salvorion.Roster.Person
    belongs_to :source_event, Salvorion.Accountability.AccountabilityEvent
    # The losing event when a scan and a roll-call mark disagree (FR-ROLL-05).
    # Non-nil means "flagged for the warden"; cleared by setting
    # contradiction_resolved_at when the warden confirms.
    belongs_to :contradicting_event, Salvorion.Accountability.AccountabilityEvent

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(person_status, attrs) do
    person_status
    |> cast(attrs, [
      :activation_id,
      :person_id,
      :status,
      :source_event_id,
      :contradicting_event_id,
      :contradiction_resolved_at
    ])
    |> validate_required([:activation_id, :person_id, :status])
    |> validate_inclusion(:status, unquote(@statuses))
    |> unique_constraint([:activation_id, :person_id])
    |> foreign_key_constraint(:activation_id)
    |> foreign_key_constraint(:person_id)
  end
end
