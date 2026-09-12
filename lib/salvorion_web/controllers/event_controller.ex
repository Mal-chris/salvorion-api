defmodule SalvorionWeb.EventController do
  @moduledoc """
  Accountability event ingest (Task 8): sign-ins, roll-call marks,
  overrides and contradiction confirmations all funnel through
  `Accountability.ingest_event/2`. admin, osh_officer, warden — this
  covers "Perform sign-in (scan/manual)" and "Register a visitor"
  (Document 10 section 1, both Yes/Yes/Yes/No); the `override` kind's
  extra osh_officer/admin-only check already lives inside
  `ingest_event/2` (Prompt 6) and is not duplicated here.
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accountability
  alias Salvorion.Accountability.{AccountabilityEvent, PersonStatus}

  def create(conn, %{"id" => activation_id} = params) do
    attrs =
      params
      |> Map.delete("id")
      |> Map.put("activation_id", activation_id)
      |> Map.put_new("recorded_by_id", conn.assigns.current_user_id)

    case Accountability.ingest_event(attrs, actor: conn.assigns.current_user_id) do
      {:ok, event, :duplicate} ->
        conn |> put_status(:ok) |> json(%{data: event_json(event, nil, duplicate: true)})

      {:ok, event, %PersonStatus{} = status} ->
        conn |> put_status(:created) |> json(%{data: event_json(event, status)})

      {:error, _} = error ->
        error
    end
  end

  defp event_json(%AccountabilityEvent{} = e, status, opts \\ []) do
    %{
      id: e.id,
      client_uuid: e.client_uuid,
      activation_id: e.activation_id,
      person_id: e.person_id,
      kind: e.kind,
      status: e.status,
      server_timestamp: e.server_timestamp,
      duplicate: Keyword.get(opts, :duplicate, false)
    }
    |> Map.put(:person_status, status && status_json(status))
  end

  defp status_json(%PersonStatus{} = s),
    do: %{
      status: s.status,
      contradiction_open?:
        not is_nil(s.contradicting_event_id) and is_nil(s.contradiction_resolved_at)
    }
end
