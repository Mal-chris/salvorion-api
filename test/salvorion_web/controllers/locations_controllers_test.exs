defmodule SalvorionWeb.LocationsControllersTest do
  @moduledoc """
  Assembly points, zones, areas (Task 5): any authenticated read,
  admin/osh_officer write (Document 10 section 1, "Manage assembly
  points, zones, areas"), so tested together.
  """
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.Locations

  describe "assembly points" do
    test "any authenticated role can list and view the hierarchy", %{conn: conn} do
      {:ok, _} = Locations.create_assembly_point(%{name: "AP One"})

      for role <- SalvorionWeb.RBAC.roles() do
        user = user_fixture(%{role: role})

        assert %{"data" => [_ | _]} =
                 json_response(conn |> authed(user) |> get(~p"/api/assembly-points"), 200)

        assert %{"data" => list} =
                 json_response(
                   conn |> authed(user) |> get(~p"/api/assembly-points/hierarchy"),
                   200
                 )

        assert is_list(list)
      end
    end

    test "admin/osh_officer create; warden gets 403", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      conn1 = conn |> authed(admin) |> post(~p"/api/assembly-points", %{name: "New AP"})
      assert %{"data" => %{"name" => "New AP"}} = json_response(conn1, 201)

      osh = user_fixture(%{role: "osh_officer"})
      conn2 = conn |> authed(osh) |> post(~p"/api/assembly-points", %{name: "Another AP"})
      assert %{"data" => %{"name" => "Another AP"}} = json_response(conn2, 201)

      warden = user_fixture(%{role: "warden"})
      conn3 = conn |> authed(warden) |> post(~p"/api/assembly-points", %{name: "Nope"})
      assert json_response(conn3, 403)
    end
  end

  describe "zones" do
    test "any role lists; admin/osh_officer create, warden gets 403", %{conn: conn} do
      {:ok, ap} = Locations.create_assembly_point(%{name: "Zone Test AP"})
      user = user_fixture()
      assert json_response(conn |> authed(user) |> get(~p"/api/zones"), 200)

      admin = user_fixture(%{role: "admin"})

      conn1 =
        conn |> authed(admin) |> post(~p"/api/zones", %{number: 9901, assembly_point_id: ap.id})

      assert %{"data" => %{"number" => 9901}} = json_response(conn1, 201)

      warden = user_fixture(%{role: "warden"})

      conn2 =
        conn |> authed(warden) |> post(~p"/api/zones", %{number: 9902, assembly_point_id: ap.id})

      assert json_response(conn2, 403)
    end
  end

  describe "areas, and their department links" do
    test "any role lists (optionally by zone_id); admin/osh_officer create, warden gets 403", %{
      conn: conn
    } do
      zone = zone_fixture()
      {:ok, area} = Locations.create_area(%{name: "Area X", zone_id: zone.id})

      user = user_fixture()

      assert %{"data" => [_ | _]} =
               json_response(conn |> authed(user) |> get(~p"/api/areas"), 200)

      filtered = conn |> authed(user) |> get(~p"/api/areas?zone_id=#{zone.id}")
      assert %{"data" => [%{"id" => id}]} = json_response(filtered, 200)
      assert id == area.id

      admin = user_fixture(%{role: "admin"})
      conn1 = conn |> authed(admin) |> post(~p"/api/areas", %{name: "Area Y", zone_id: zone.id})
      assert %{"data" => %{"name" => "Area Y"}} = json_response(conn1, 201)

      warden = user_fixture(%{role: "warden"})
      conn2 = conn |> authed(warden) |> post(~p"/api/areas", %{name: "Area Z", zone_id: zone.id})
      assert json_response(conn2, 403)
    end

    test "admin/osh_officer link and unlink a department; warden gets 403 on both", %{conn: conn} do
      zone = zone_fixture()
      {:ok, area} = Locations.create_area(%{name: "Linkable Area", zone_id: zone.id})
      dept = department_fixture()

      admin = user_fixture(%{role: "admin"})

      link_conn =
        conn
        |> authed(admin)
        |> post(~p"/api/areas/#{area.id}/departments", %{department_id: dept.id})

      assert %{"data" => %{"department_id" => department_id, "area_id" => area_id}} =
               json_response(link_conn, 201)

      assert department_id == dept.id
      assert area_id == area.id

      unlink_conn =
        conn |> authed(admin) |> delete(~p"/api/areas/#{area.id}/departments/#{dept.id}")

      assert response(unlink_conn, 204)

      warden = user_fixture(%{role: "warden"})
      dept2 = department_fixture()

      forbidden_link =
        conn
        |> authed(warden)
        |> post(~p"/api/areas/#{area.id}/departments", %{department_id: dept2.id})

      assert json_response(forbidden_link, 403)

      {:ok, _} = Locations.link_department_to_area(dept2, area)

      forbidden_unlink =
        conn |> authed(warden) |> delete(~p"/api/areas/#{area.id}/departments/#{dept2.id}")

      assert json_response(forbidden_unlink, 403)
    end
  end
end
