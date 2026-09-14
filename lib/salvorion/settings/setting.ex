defmodule Salvorion.Settings.Setting do
  @moduledoc """
  Key/value configuration, used so that OSH decisions still
  pending at design time never require a code change once
  answered. See Technical Foundation (03), section 5. Known keys
  used elsewhere in the codebase:

    - "student_accountability_rule" => one of
        "all_enrolled" | "signed_in_only" | "timetable_expected"
    - "visitor_retention_days" => integer, default 90
    - "id_barcode_parser" => reserved/planned key, not yet consulted
        by any code path; intended to select which parser maps a raw
        scan payload to Person.id_number, once more than one exists
    - "offline_login_grace_hours" => reserved/planned key, not yet
        consulted by any code path; intended to hold how long a cached
        credential remains usable with no connectivity (FR-USR-04),
        once the mobile app (Stage C) exists to consult it
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "settings" do
    field :value, :map

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(setting, attrs) do
    setting
    |> cast(attrs, [:key, :value])
    |> validate_required([:key, :value])
  end
end
