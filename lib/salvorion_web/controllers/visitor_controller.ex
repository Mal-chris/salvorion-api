defmodule SalvorionWeb.VisitorController do
  @moduledoc """
  Visitor registration (Task 6; Document 10 section 1, "Register a
  visitor": admin, osh_officer, warden).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accountability.AccountabilityEvent
  alias Salvorion.Roster
  alias Salvorion.Roster.Person

  @doc """
  `{"first_name", "last_name", "visitor_host", "phone"?, "email"?,
  "visitor_expires_at"?, "activation_id"?, "assembly_point_id"?,
  "area_id"?, "device_id"?}`.

  Registering at an assembly point during an activation (`activation_id`
  given) also signs the visitor in. Per `Roster.register_visitor/2`, a
  failed sign-in (e.g. the activation has since closed) does not undo
  the registration — the person is still returned with `sign_in_error`
  set, at 201, not funnelled through the fallback controller as if the
  whole request failed.
  """
  def create(conn, params) do
    opts =
      [actor: conn.assigns.current_user_id, recorded_by_id: conn.assigns.current_user_id]
      |> maybe_put(:activation_id, params["activation_id"])
      |> maybe_put(:assembly_point_id, params["assembly_point_id"])
      |> maybe_put(:area_id, params["area_id"])
      |> maybe_put(:device_id, params["device_id"])
      |> maybe_put(:client_uuid, params["client_uuid"])
      |> maybe_put(:client_timestamp, parse_timestamp(params["client_timestamp"]))

    with {:ok, person, sign_in_result} <- Roster.register_visitor(params, opts) do
      conn
      |> put_status(:created)
      |> json(%{data: visitor_json(person, sign_in_result)})
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_timestamp(nil), do: nil

  defp parse_timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp visitor_json(%Person{} = person, sign_in_result) do
    %{
      person: %{
        id: person.id,
        type: person.type,
        id_number: person.id_number,
        first_name: person.first_name,
        last_name: person.last_name,
        visitor_host: person.visitor_host,
        visitor_expires_at: person.visitor_expires_at
      },
      pass: Roster.visitor_pass(person)
    }
    |> Map.merge(sign_in_json(sign_in_result))
  end

  defp sign_in_json(nil), do: %{event: nil}

  defp sign_in_json(%AccountabilityEvent{} = event),
    do: %{event: %{id: event.id, kind: event.kind, status: event.status}}

  defp sign_in_json({:error, reason}), do: %{event: nil, sign_in_error: to_string(reason)}
end
