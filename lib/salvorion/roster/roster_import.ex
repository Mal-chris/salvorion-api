defmodule Salvorion.Roster.RosterImport do
  @moduledoc """
  A record of one roster import run, regardless of which
  RosterProvider performed it. See Salvorion.Roster.Provider
  for the behaviour every provider implements.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @providers ~w(file_import scheduled_export direct_database synthetic)

  schema "roster_imports" do
    field :provider, :string
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :total_records, :integer
    field :error_count, :integer
    field :errors, :map

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(roster_import, attrs) do
    roster_import
    |> cast(attrs, [:provider, :started_at, :completed_at, :total_records, :error_count, :errors])
    |> validate_required([:provider, :started_at])
    |> validate_inclusion(:provider, unquote(@providers))
  end
end
