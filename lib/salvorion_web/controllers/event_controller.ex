defmodule SalvorionWeb.EventController do
  @moduledoc """
  Accountability event ingest (Task 8): sign-ins, roll-call marks,
  overrides and contradiction confirmations all funnel through
  `Accountability.ingest_event/2`. admin, osh_officer, warden — this
  covers "Perform sign-in (scan/manual)" and "Register a visitor"
  (Document 10 section 1, both Yes/Yes/Yes/No); the `override` kind's
  extra osh_officer/admin-only check already lives inside
  `ingest_event/2` (Prompt 6) and is not duplicated here — but that
  check only means anything because `recorded_by_id` below is always
  the authenticated caller, never a client-supplied value (docs/DECISIONS.md,
  "event attribution could be forged via recorded_by_id").
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accountability
  alias Salvorion.Accountability.{AccountabilityEvent, PersonStatus}
  alias Salvorion.Accounts
  alias Salvorion.Accounts.Device

  def create(conn, %{"id" => activation_id} = params) do
    with :ok <- validate_device(params["device_id"], conn.assigns.current_user_id) do
      # Map.put, never Map.put_new: recorded_by_id and the override-permission
      # check that reads it (Accountability.check_override_permitted/1) must
      # never trust a value the request body supplied — overwrite whatever
      # the client sent, unconditionally, with the authenticated caller.
      attrs =
        params
        |> Map.delete("id")
        |> Map.put("activation_id", activation_id)
        |> Map.put("recorded_by_id", conn.assigns.current_user_id)

      case Accountability.ingest_event(attrs, actor: conn.assigns.current_user_id) do
        {:ok, event, :duplicate} ->
          conn |> put_status(:ok) |> json(%{data: event_json(event, nil, duplicate: true)})

        {:ok, event, %PersonStatus{} = status} ->
          conn |> put_status(:created) |> json(%{data: event_json(event, status)})

        {:error, _} = error ->
          error
      end
    end
  end

  # A device_id in the request must belong to the authenticated caller —
  # otherwise any authenticated user could attribute an event to any
  # device on file, defeating device-level attribution entirely. A
  # missing device_id is fine (not every sign-in station is a registered
  # device); an unknown or someone-else's device_id is not.
  defp validate_device(nil, _user_id), do: :ok

  defp validate_device(device_id, user_id) do
    case Accounts.get_device(device_id) do
      %Device{user_id: ^user_id} -> :ok
      _ -> {:error, :forbidden}
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
