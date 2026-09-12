defmodule SalvorionWeb.Plugs.AuthorizeTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Accounts
  alias SalvorionWeb.Plugs.Authorize
  alias SalvorionWeb.RBAC

  defp authed_conn(role) do
    user = user_fixture(%{role: role})
    {:ok, tokens} = Accounts.issue_tokens(user)

    build_conn(:get, "/api/whatever")
    |> put_req_header("authorization", "Bearer " <> tokens.access_token)
    |> Plug.Conn.put_private(:phoenix_router, SalvorionWeb.Router)
  end

  test "RBAC.allowed_roles/2 reads the matrix and reports undeclared routes" do
    assert RBAC.allowed_roles("GET", "/api/auth/me") == RBAC.roles()
    assert RBAC.allowed_roles("get", "/api/users") == ["admin"]
    assert RBAC.allowed_roles("GET", "/api/does-not-exist") == :undeclared
  end

  test "pipeline-level roles: allowed role passes, others get 403" do
    conn = Authorize.call(authed_conn("admin"), Authorize.init(roles: ["admin"]))
    refute conn.halted
    assert conn.assigns.current_role == "admin"

    conn = Authorize.call(authed_conn("warden"), Authorize.init(roles: ["admin"]))
    assert conn.halted
    assert conn.status == 403
  end

  test "a route with no RBAC row is denied for everyone (fail closed)" do
    for role <- RBAC.roles() do
      conn = Authorize.call(authed_conn(role), Authorize.init([]))
      assert conn.halted
      assert conn.status == 403
    end
  end

  test "missing or malformed token is 401, not 403" do
    conn = Authorize.call(build_conn(:get, "/api/whatever"), Authorize.init(roles: RBAC.roles()))
    assert conn.status == 401

    conn =
      build_conn(:get, "/api/whatever")
      |> put_req_header("authorization", "Basic abc")
      |> Authorize.call(Authorize.init(roles: RBAC.roles()))

    assert conn.status == 401
  end
end
