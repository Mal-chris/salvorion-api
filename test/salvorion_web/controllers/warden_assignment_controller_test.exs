defmodule SalvorionWeb.WardenAssignmentControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Accounts

  describe "POST /api/warden-assignments" do
    test "admin and osh_officer can assign a warden to a zone", %{conn: conn} do
      for role <- ["admin", "osh_officer"] do
        actor = user_fixture(%{role: role})
        warden = user_fixture(%{role: "warden"})
        zone = zone_fixture()

        conn =
          conn
          |> authed(actor)
          |> post(~p"/api/warden-assignments", %{
            user_id: warden.id,
            zone_id: zone.id,
            starts_at: "2026-01-01"
          })

        assert %{"data" => %{"zone_id" => zone_id, "area_id" => nil}} = json_response(conn, 201)
        assert zone_id == zone.id
      end
    end

    test "warden gets 403", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})
      zone = zone_fixture()

      conn =
        conn
        |> authed(warden)
        |> post(~p"/api/warden-assignments", %{
          user_id: warden.id,
          zone_id: zone.id,
          starts_at: "2026-01-01"
        })

      assert json_response(conn, 403)
    end

    test "a malformed date is a 422 field error, not a 500", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      warden = user_fixture(%{role: "warden"})
      zone = zone_fixture()

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/warden-assignments", %{
          user_id: warden.id,
          zone_id: zone.id,
          starts_at: "not-a-date"
        })

      assert %{"errors" => %{"starts_at" => [_]}} = json_response(conn, 422)
    end

    test "neither zone_id nor area_id is a 422 field error", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      warden = user_fixture(%{role: "warden"})

      conn =
        conn
        |> authed(admin)
        |> post(~p"/api/warden-assignments", %{user_id: warden.id, starts_at: "2026-01-01"})

      assert %{"errors" => %{"zone_id" => [_]}} = json_response(conn, 422)
    end
  end

  describe "GET /api/warden-assignments" do
    test "admin and osh_officer can list, optionally filtered by user_id", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})
      zone = zone_fixture()

      {:ok, assignment} =
        Accounts.assign_warden(warden.id, {:zone, zone.id}, {~D[2026-01-01], nil})

      other_warden = user_fixture(%{role: "warden"})

      {:ok, _other} =
        Accounts.assign_warden(other_warden.id, {:zone, zone.id}, {~D[2026-01-01], nil})

      admin = user_fixture(%{role: "admin"})
      conn = conn |> authed(admin) |> get(~p"/api/warden-assignments", %{user_id: warden.id})

      assert %{"data" => [%{"id" => id}]} = json_response(conn, 200)
      assert id == assignment.id
    end

    test "report_viewer gets 403", %{conn: conn} do
      viewer = user_fixture(%{role: "report_viewer"})
      conn = conn |> authed(viewer) |> get(~p"/api/warden-assignments")
      assert json_response(conn, 403)
    end
  end
end
