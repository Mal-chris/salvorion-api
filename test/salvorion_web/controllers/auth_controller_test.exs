defmodule SalvorionWeb.AuthControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Accounts

  describe "POST /api/auth/login" do
    test "returns tokens for valid credentials", %{conn: conn} do
      user = user_fixture()

      conn = post(conn, ~p"/api/auth/login", %{email: user.email, password: valid_password()})

      assert %{
               "access_token" => access,
               "refresh_token" => refresh,
               "expires_in" => 900,
               "token_type" => "Bearer"
             } =
               json_response(conn, 200)

      assert {:ok, %{"typ" => "access"}} = Accounts.Guardian.decode_and_verify(access)
      assert {:ok, %{"typ" => "refresh"}} = Accounts.Guardian.decode_and_verify(refresh)
    end

    test "returns the same 401 for unknown email, wrong password and missing fields", %{
      conn: conn
    } do
      user = user_fixture()
      expected = %{"errors" => %{"detail" => "invalid credentials"}}

      assert json_response(
               post(conn, ~p"/api/auth/login", %{email: "x@y.test", password: "p"}),
               401
             ) == expected

      assert json_response(
               post(conn, ~p"/api/auth/login", %{email: user.email, password: "nope"}),
               401
             ) == expected

      assert json_response(post(conn, ~p"/api/auth/login", %{}), 401) == expected
    end

    test "binds tokens to a device and rejects a device belonging to someone else", %{conn: conn} do
      user = user_fixture()
      other = user_fixture()
      device = device_fixture(user)
      other_device = device_fixture(other)

      conn1 =
        post(conn, ~p"/api/auth/login", %{
          email: user.email,
          password: valid_password(),
          device_id: device.id
        })

      %{"access_token" => access} = json_response(conn1, 200)
      assert {:ok, %{"device_id" => did}} = Accounts.Guardian.decode_and_verify(access)
      assert did == device.id

      conn2 =
        post(conn, ~p"/api/auth/login", %{
          email: user.email,
          password: valid_password(),
          device_id: other_device.id
        })

      assert json_response(conn2, 401)
    end
  end

  describe "POST /api/auth/refresh" do
    test "rotates tokens", %{conn: conn} do
      user = user_fixture()
      {:ok, tokens} = Accounts.issue_tokens(user)

      conn = post(conn, ~p"/api/auth/refresh", %{refresh_token: tokens.refresh_token})
      assert %{"access_token" => _, "refresh_token" => _} = json_response(conn, 200)

      conn = post(build_conn(), ~p"/api/auth/refresh", %{refresh_token: tokens.access_token})
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/auth/me" do
    test "requires a valid access token", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/auth/me"), 401)

      assert json_response(
               get(put_req_header(conn, "authorization", "Bearer nope"), ~p"/api/auth/me"),
               401
             )
    end

    test "works for every role", %{conn: conn} do
      for role <- SalvorionWeb.RBAC.roles() do
        user = user_fixture(%{role: role})
        {:ok, tokens} = Accounts.issue_tokens(user)

        conn =
          get(
            put_req_header(conn, "authorization", "Bearer " <> tokens.access_token),
            ~p"/api/auth/me"
          )

        assert %{"user_id" => id, "role" => ^role} = json_response(conn, 200)
        assert id == user.id
      end
    end

    test "rejects tokens bound to a revoked device", %{conn: conn} do
      user = user_fixture()
      device = device_fixture(user)
      {:ok, tokens} = Accounts.issue_tokens(user, device_id: device.id)
      authed = put_req_header(conn, "authorization", "Bearer " <> tokens.access_token)

      assert json_response(get(authed, ~p"/api/auth/me"), 200)

      {:ok, _} = Accounts.revoke_device(device, actor: user)
      assert json_response(get(authed, ~p"/api/auth/me"), 401)
    end

    test "rejects a still-unexpired token once its user has been deactivated (Document 25, Task 7)",
         %{conn: conn} do
      user = user_fixture()
      {:ok, tokens} = Accounts.issue_tokens(user)
      authed = put_req_header(conn, "authorization", "Bearer " <> tokens.access_token)

      assert json_response(get(authed, ~p"/api/auth/me"), 200)

      {:ok, _} = Accounts.deactivate_user(user, actor: user)
      assert json_response(get(authed, ~p"/api/auth/me"), 401)
    end
  end

  describe "GET /.well-known/jwks.json" do
    test "is public and returns one RSA key whose kid matches issued tokens", %{conn: conn} do
      user = user_fixture()
      {:ok, tokens} = Accounts.issue_tokens(user)
      %{headers: %{"kid" => token_kid}} = Accounts.Guardian.peek(tokens.access_token)

      assert %{"keys" => [key]} = json_response(get(conn, "/.well-known/jwks.json"), 200)
      assert key["kty"] == "RSA"
      assert key["alg"] == "RS256"
      assert key["use"] == "sig"
      assert key["kid"] == token_kid
      assert is_binary(key["n"]) and is_binary(key["e"])
      refute Map.has_key?(key, "d")

      # The published key verifies the token (what PowerSync will do).
      jwk = JOSE.JWK.from_map(key)
      assert {true, _, _} = JOSE.JWT.verify_strict(jwk, ["RS256"], tokens.access_token)
    end
  end
end
