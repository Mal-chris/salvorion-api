defmodule SalvorionWeb.AuthController do
  use SalvorionWeb, :controller

  alias Salvorion.Accounts

  @doc """
  POST /api/auth/login  {"email": ..., "password": ..., "device_id": optional}

  Returns access + refresh tokens. On any failure answers 401 with nothing
  more specific than "invalid credentials".
  """
  def login(conn, params) do
    email = Map.get(params, "email")
    password = Map.get(params, "password")
    device_id = Map.get(params, "device_id")

    with true <- is_binary(email) and is_binary(password),
         {:ok, user} <- Accounts.authenticate_user(email, password),
         :ok <- check_device_for_user(user, device_id),
         {:ok, tokens} <- Accounts.issue_tokens(user, device_id: device_id) do
      json(conn, tokens)
    else
      _ -> invalid_credentials(conn)
    end
  end

  @doc "POST /api/auth/refresh  {\"refresh_token\": ...}"
  def refresh(conn, %{"refresh_token" => token}) when is_binary(token) do
    case Accounts.refresh_tokens(token) do
      {:ok, tokens} -> json(conn, tokens)
      {:error, _} -> invalid_credentials(conn)
    end
  end

  def refresh(conn, _params), do: invalid_credentials(conn)

  @doc "GET /api/auth/me - the caller's identity as carried by the token."
  def me(conn, _params) do
    json(conn, %{
      user_id: conn.assigns.current_user_id,
      role: conn.assigns.current_role,
      device_id: conn.assigns.current_device_id
    })
  end

  # A device id sent at login must belong to this user and not be revoked;
  # otherwise the login fails with the same generic 401.
  defp check_device_for_user(_user, nil), do: :ok

  defp check_device_for_user(user, device_id) when is_binary(device_id) do
    case Accounts.get_device(device_id) do
      %{user_id: uid, revoked_at: nil} when uid == user.id -> :ok
      _ -> {:error, :invalid_device}
    end
  end

  defp check_device_for_user(_user, _), do: {:error, :invalid_device}

  defp invalid_credentials(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{errors: %{detail: "invalid credentials"}})
  end
end
