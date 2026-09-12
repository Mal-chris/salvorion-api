defmodule SalvorionWeb.DeviceController do
  @moduledoc """
  Device registration and revocation (Task 3; Document 10 section 4).

  `create/2` is self-registration: any authenticated role may register a
  device for themselves. `revoke/2`'s permission ("admin, or the
  device's own user") cannot be expressed as a route-level role list —
  the RBAC row allows every role through, and this controller does the
  actual admin-or-owner check itself (see `SalvorionWeb.RBAC`'s
  moduledoc).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accounts
  alias Salvorion.Accounts.Device

  def create(conn, params) do
    user = Accounts.get_user!(conn.assigns.current_user_id)

    with {:ok, device} <- Accounts.register_device(user, params, actor: user) do
      conn |> put_status(:created) |> json(%{data: device_json(device)})
    end
  end

  def revoke(conn, %{"id" => id}) do
    case Accounts.get_device(id) do
      nil ->
        {:error, :not_found}

      %Device{} = device ->
        if conn.assigns.current_role == "admin" or device.user_id == conn.assigns.current_user_id do
          with {:ok, device} <-
                 Accounts.revoke_device(device, actor: conn.assigns.current_user_id) do
            json(conn, %{data: device_json(device)})
          end
        else
          {:error, :forbidden}
        end
    end
  end

  defp device_json(%Device{} = d),
    do: %{id: d.id, user_id: d.user_id, platform: d.platform, revoked_at: d.revoked_at}
end
