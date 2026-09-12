defmodule SalvorionWeb.UserControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  describe "POST /api/users" do
    test "admin creates a user", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/users", %{
          email: unique_email(),
          password: valid_password(),
          role: "warden"
        })

      assert %{"data" => %{"role" => "warden"}} = json_response(conn, 201)
    end

    test "warden gets 403", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})

      conn =
        conn
        |> authed(warden)
        |> post(~p"/api/users", %{
          email: unique_email(),
          password: valid_password(),
          role: "warden"
        })

      assert json_response(conn, 403)
    end

    test "no token gets 401", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/users", %{}), 401)
    end

    test "invalid attrs return 422 with field errors", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      conn = conn |> authed(admin) |> post(~p"/api/users", %{})
      assert %{"errors" => errors} = json_response(conn, 422)
      assert Map.has_key?(errors, "email")
    end
  end

  describe "GET /api/users and /api/users/:id" do
    test "admin lists and fetches users", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      other = user_fixture()

      index_conn = conn |> authed(admin) |> get(~p"/api/users")
      ids = index_conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["id"])
      assert other.id in ids

      show_conn = conn |> authed(admin) |> get(~p"/api/users/#{other.id}")
      assert %{"data" => %{"id" => id}} = json_response(show_conn, 200)
      assert id == other.id
    end

    test "report_viewer gets 403 on both", %{conn: conn} do
      viewer = user_fixture(%{role: "report_viewer"})
      other = user_fixture()

      assert json_response(conn |> authed(viewer) |> get(~p"/api/users"), 403)
      assert json_response(conn |> authed(viewer) |> get(~p"/api/users/#{other.id}"), 403)
    end
  end

  describe "PATCH /api/users/:id/role" do
    test "admin changes a role", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      target = user_fixture(%{role: "warden"})

      conn =
        conn |> authed(admin) |> patch(~p"/api/users/#{target.id}/role", %{role: "osh_officer"})

      assert %{"data" => %{"role" => "osh_officer"}} = json_response(conn, 200)
    end

    test "osh_officer gets 403", %{conn: conn} do
      osh = user_fixture(%{role: "osh_officer"})
      target = user_fixture()

      conn = conn |> authed(osh) |> patch(~p"/api/users/#{target.id}/role", %{role: "admin"})
      assert json_response(conn, 403)
    end
  end

  describe "POST /api/users/:id/deactivate" do
    test "admin deactivates a user", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      target = user_fixture()

      conn = conn |> authed(admin) |> post(~p"/api/users/#{target.id}/deactivate")
      assert %{"data" => %{"active" => false}} = json_response(conn, 200)
    end

    test "warden gets 403", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})
      target = user_fixture()

      conn = conn |> authed(warden) |> post(~p"/api/users/#{target.id}/deactivate")
      assert json_response(conn, 403)
    end
  end
end
