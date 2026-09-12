defmodule Salvorion.Accounts.Keys do
  @moduledoc """
  Loads the RS256 signing key pair used by `Salvorion.Accounts.Guardian`.

  The private key is read once, at application start (`load!/0`), from the
  PEM file named by `config :salvorion, Salvorion.Accounts.Keys,
  private_key_path: ...` (set in `config/runtime.exs` from
  `GUARDIAN_PRIVATE_KEY_PATH`). The parsed `JOSE.JWK` is kept in
  `:persistent_term`, so signing and verifying never touch the disk again.

  The key ID (`kid`) is the RFC 7638 JWK thumbprint of the public key, so it
  is stable for a given key, appears in every issued token's header, and is
  the same value published by the JWKS endpoint.
  """

  alias JOSE.JWK

  @term {__MODULE__, :signing_jwk}

  @doc "Reads the configured PEM file and caches the JWK. Raises if unusable."
  @spec load!() :: :ok
  def load! do
    path = private_key_path()

    unless File.exists?(path) do
      raise """
      Guardian signing key not found at #{path}.
      Generate a development key pair with:
        mkdir -p priv/keys
        openssl genrsa -out priv/keys/dev_private.pem 2048
        openssl rsa -in priv/keys/dev_private.pem -pubout -out priv/keys/dev_public.pem
      or point GUARDIAN_PRIVATE_KEY_PATH at an existing RSA private key.
      """
    end

    jwk = JWK.from_pem_file(path)

    unless match?(%JWK{kty: {:jose_jwk_kty_rsa, _}}, jwk) do
      raise "Guardian signing key at #{path} is not an RSA key; RS256 requires one."
    end

    kid = JWK.thumbprint(jwk)

    jwk = %JWK{
      jwk
      | fields: Map.merge(jwk.fields, %{"kid" => kid, "alg" => "RS256", "use" => "sig"})
    }

    :persistent_term.put(@term, jwk)
    :ok
  end

  @doc "The private JWK used to sign tokens. Consulted by Guardian via config."
  @spec signing_jwk() :: JWK.t()
  def signing_jwk do
    case :persistent_term.get(@term, nil) do
      nil ->
        load!()
        :persistent_term.get(@term)

      jwk ->
        jwk
    end
  end

  @doc "The stable key ID placed in token headers and in the JWKS."
  @spec kid() :: String.t()
  def kid, do: signing_jwk().fields["kid"]

  @doc """
  The public half of the signing key as a plain JWK map (RFC 7517), ready to
  be placed in a JWKS `keys` array. Derived by `jose`, not hand-rolled.
  """
  @spec public_jwk_map() :: map()
  def public_jwk_map do
    {_kty, map} = signing_jwk() |> JWK.to_public() |> JWK.to_map()
    map
  end

  defp private_key_path do
    Application.get_env(:salvorion, __MODULE__, [])
    |> Keyword.get(:private_key_path)
    |> case do
      nil -> raise "config :salvorion, Salvorion.Accounts.Keys, private_key_path: ... is not set"
      path -> Path.expand(path)
    end
  end
end
