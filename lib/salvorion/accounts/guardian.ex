defmodule Salvorion.Accounts.Guardian do
  @moduledoc """
  Guardian implementation for Salvorion.

  Tokens are RS256 JWTs signed with the private key from
  `Salvorion.Accounts.Keys` (see `config/config.exs`). Every token carries:

    * `sub`  - the user's id
    * `role` - the user's role, so `SalvorionWeb.Plugs.Authorize` can check
      permissions without a database round-trip per request
    * `typ`  - `"access"` (15 min) or `"refresh"` (30 days)
    * `device_id` - optional; set when the login was tied to a registered
      device so revocation (`devices.revoked_at`) can be enforced
    * `aud` - includes `"powersync"` so the same access token authenticates
      the client to the PowerSync service (`client_auth.audience`)
  """

  use Guardian, otp_app: :salvorion

  alias Salvorion.Accounts
  alias Salvorion.Accounts.User

  @impl true
  def subject_for_token(%User{id: id}, _claims), do: {:ok, id}
  def subject_for_token(_, _), do: {:error, :unhandled_resource_type}

  @impl true
  def resource_from_claims(%{"sub" => id}) do
    case Accounts.get_user(id) do
      nil -> {:error, :resource_not_found}
      user -> {:ok, user}
    end
  end

  def resource_from_claims(_), do: {:error, :resource_not_found}

  @impl true
  def build_claims(claims, %User{role: role}, _opts) do
    claims =
      claims
      |> Map.put("role", role)
      |> Map.put("aud", [config(:issuer), "powersync"])

    {:ok, claims}
  end

  @doc """
  Verifies an access token exactly as `SalvorionWeb.Plugs.Authorize` and
  `SalvorionWeb.UserSocket` both need to: decode/verify the JWT (RS256,
  `typ == "access"`), reject a revoked device if the token carries a
  `device_id` claim (Document 10, section 4), and reject a deactivated
  user (Document 25, Task 7 — the same symmetric treatment: a
  deactivated user's still-unexpired token must stop authenticating,
  not keep working for up to 15 minutes the way it did before this
  check existed). The one place both call this, so an HTTP request and
  a long-lived channel connection can never drift apart on what "a
  valid token" means.
  """
  @spec verify_access_token(String.t()) :: {:ok, map} | {:error, term}
  def verify_access_token(token) do
    with {:ok, claims} <- decode_and_verify(token, %{"typ" => "access"}),
         :ok <- check_device(claims),
         :ok <- check_active(claims) do
      {:ok, claims}
    end
  end

  defp check_device(%{"device_id" => device_id}) when is_binary(device_id) do
    if Accounts.device_revoked?(device_id), do: {:error, :device_revoked}, else: :ok
  end

  defp check_device(_claims), do: :ok

  defp check_active(%{"sub" => user_id}) do
    if Accounts.user_deactivated?(user_id), do: {:error, :user_deactivated}, else: :ok
  end

  defp check_active(_claims), do: :ok
end
