defmodule SalvorionWeb.UserSocket do
  @moduledoc """
  The real-time layer's entry point (Prompt 12, Task 1; Document 07
  section 3's "Phoenix Channels" component). A client connects once,
  presenting the same RS256 access token it already holds for the HTTP
  API, and joins one or more channels on top of that single socket.

  Authentication happens here, once, at connect time — not per channel
  join, and never re-derived: `Salvorion.Accounts.Guardian.verify_access_token/1`
  is the exact same check `SalvorionWeb.Plugs.Authorize` runs on every
  HTTP request (signature, expiry, `typ == "access"`, that the token's
  `device_id` — if any — is not revoked, and that the token's user is
  still `active`, Document 25 Task 7). A connection that fails this is
  rejected outright (`:error`); there is no path where a socket is
  accepted and only rejected later at join, because a rejected
  `connect/3` never gets far enough to attempt one.
  """

  use Phoenix.Socket

  alias Salvorion.Accounts.Guardian

  channel "activation:*", SalvorionWeb.ActivationChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) when is_binary(token) do
    case Guardian.verify_access_token(token) do
      {:ok, claims} ->
        {:ok,
         socket
         |> assign(:current_user_id, claims["sub"])
         |> assign(:current_role, claims["role"])
         |> assign(:current_device_id, claims["device_id"])
         |> assign(:token_claims, claims)}

      {:error, _reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  # Used to identify all sockets for a given user so they can all be
  # disconnected at once (e.g. `Endpoint.broadcast("user_socket:123", ...)`)
  # if a future prompt needs to force-log-out every device a user holds,
  # not just one (Task 3 here only ever needs to close one channel on one
  # device's own socket).
  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user_id}"
end
