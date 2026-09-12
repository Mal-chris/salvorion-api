defmodule SalvorionWeb.DashboardController do
  @moduledoc """
  The OSH/admin live dashboard reads (Task 8; Document 10 section 1,
  "View live dashboard" and "View unaccounted list (all zones)" —
  admin, osh_officer, report_viewer). A warden's own-scope view is the
  roll-call routes (`SalvorionWeb.RollCallController`), not these.
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accountability

  @unaccounted_filters ~w(department_id faculty_id zone_id type)

  def summary(conn, %{"id" => activation_id}) do
    json(conn, %{data: Accountability.activation_summary(activation_id)})
  end

  def departments(conn, %{"id" => activation_id}) do
    json(conn, %{data: Accountability.participation_by_department(activation_id)})
  end

  def faculties(conn, %{"id" => activation_id}) do
    json(conn, %{data: Accountability.participation_by_faculty(activation_id)})
  end

  def zones(conn, %{"id" => activation_id}) do
    json(conn, %{data: Accountability.counts_by_zone(activation_id)})
  end

  @doc "FR-DASH-03: filterable by department_id, faculty_id, zone_id, type; an unknown filter is ignored."
  def unaccounted(conn, %{"id" => activation_id} = params) do
    filters =
      for key <- @unaccounted_filters,
          value = params[key],
          not is_nil(value),
          do: {String.to_existing_atom(key), value}

    json(conn, %{data: Accountability.unaccounted_list(activation_id, filters)})
  end
end
