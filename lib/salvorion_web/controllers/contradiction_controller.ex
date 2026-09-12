defmodule SalvorionWeb.ContradictionController do
  @moduledoc """
  Resolving a flagged contradiction (Task 8): a warden's own "confirm"
  action, or OSH/admin's from the dashboard drill-down — warden, admin,
  osh_officer.
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accountability

  def resolve(conn, %{"id" => activation_id, "person_id" => person_id} = params) do
    opts = [actor: conn.assigns.current_user_id] ++ note_opt(params)

    with {:ok, status} <- Accountability.resolve_contradiction(activation_id, person_id, opts) do
      json(conn, %{
        data: %{
          person_id: status.person_id,
          status: status.status,
          contradiction_resolved_at: status.contradiction_resolved_at
        }
      })
    end
  end

  defp note_opt(%{"note" => note}) when is_binary(note), do: [note: note]
  defp note_opt(_), do: []
end
