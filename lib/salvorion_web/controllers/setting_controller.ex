defmodule SalvorionWeb.SettingController do
  @moduledoc """
  System settings (Document 25/26, Task 5; Document 10 §1 "Change
  system settings": admin, osh_officer).

  Known keys and their value shapes are validated here, before
  `Settings.put_setting/3` ever touches the database — an unsupported
  `student_accountability_rule` value used to only be caught as an
  `ArgumentError` the moment an activation actually started
  (`Accountability.initialise_for_activation/1`), a 500 with no warning
  beforehand (Document 25/26, finding 3.6). `"timetable_expected"` is
  still accepted here as a *storable* value — Release 1 genuinely
  doesn't reject it at the settings layer, since a future release may
  implement it — but the response carries an explicit warning that it
  is not yet functional, so choosing it here never reads as if it
  quietly worked.
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Settings

  # key => documented default (Salvorion.Settings.Setting's own
  # moduledoc). `id_barcode_parser` and `offline_login_grace_hours` are
  # documented as known keys but no code path reads either one yet
  # (Document 25/26, finding 7.4) — listed here for completeness, with
  # no default asserted, rather than inventing a number/string neither
  # the docs nor the code has ever settled on.
  @known_settings %{
    "student_accountability_rule" => "signed_in_only",
    "visitor_retention_days" => 90,
    "id_barcode_parser" => nil,
    "offline_login_grace_hours" => nil
  }

  @student_rule_values ~w(signed_in_only all_enrolled timetable_expected)

  @doc "GET /api/settings — every known key, its current value or documented default."
  def index(conn, _params) do
    data =
      for {key, default} <- @known_settings do
        %{key: key, value: Settings.get_setting(key, default)}
      end

    json(conn, %{data: Enum.sort_by(data, & &1.key)})
  end

  @doc "PATCH /api/settings/:key  {\"value\": ...}"
  def update(conn, %{"key" => key} = params) do
    case validate(key, params["value"]) do
      {:ok, value} ->
        case Settings.put_setting(key, value, actor: conn.assigns.current_user_id) do
          {:ok, _setting} ->
            json(conn, %{data: %{key: key, value: value}, warnings: warnings_for(key, value)})

          {:error, %Ecto.Changeset{} = changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{errors: SalvorionWeb.FallbackController.changeset_errors(changeset)})
        end

      {:error, message} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{value: [message]}})
    end
  end

  defp validate("student_accountability_rule", value) when value in @student_rule_values,
    do: {:ok, value}

  defp validate("student_accountability_rule", _value) do
    {:error, "must be one of: #{Enum.join(@student_rule_values, ", ")}"}
  end

  defp validate("visitor_retention_days", value) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp validate("visitor_retention_days", _value),
    do: {:error, "must be a positive integer"}

  defp validate(key, value) when is_map_key(@known_settings, key), do: {:ok, value}

  defp validate(_key, _value), do: {:error, "unknown setting key"}

  defp warnings_for("student_accountability_rule", "timetable_expected") do
    [
      "\"timetable_expected\" is stored but not yet functional in Release 1: " <>
        "starting an activation while this rule is in effect will fail " <>
        "(Salvorion.Accountability.initialise_for_activation/1 raises). " <>
        "Use \"signed_in_only\" or \"all_enrolled\" until Release 2."
    ]
  end

  defp warnings_for(_key, _value), do: []
end
