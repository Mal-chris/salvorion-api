defmodule SalvorionWeb.JWKSController do
  @moduledoc """
  GET /.well-known/jwks.json

  Publishes the RS256 public key as a JWK Set so PowerSync (and any other
  verifier) can check tokens issued by `Salvorion.Accounts.Guardian`. Public
  by design: there is nothing secret in a public key.
  """
  use SalvorionWeb, :controller

  alias Salvorion.Accounts.Keys

  def show(conn, _params) do
    conn
    |> put_resp_header("cache-control", "public, max-age=300")
    |> json(%{keys: [Keys.public_jwk_map()]})
  end
end
