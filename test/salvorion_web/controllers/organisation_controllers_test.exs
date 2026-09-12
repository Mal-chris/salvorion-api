defmodule SalvorionWeb.OrganisationControllersTest do
  @moduledoc """
  Faculties, Departments, Programmes (Task 4): same RBAC shape (any
  authenticated read, admin-only write — Document 10 section 1, "Manage
  departments, faculties, programmes": Yes/No/No/No), so tested together.
  """
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  describe "faculties" do
    test "any authenticated role can list", %{conn: conn} do
      for role <- SalvorionWeb.RBAC.roles() do
        user = user_fixture(%{role: role})
        conn = conn |> authed(user) |> get(~p"/api/faculties")
        assert %{"data" => list} = json_response(conn, 200)
        assert is_list(list)
      end
    end

    test "admin creates a faculty; osh_officer gets 403", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn1 =
        conn |> authed(admin) |> post(~p"/api/faculties", %{name: "Faculty of X", code: "FOX"})

      assert %{"data" => %{"code" => "FOX"}} = json_response(conn1, 201)

      osh = user_fixture(%{role: "osh_officer"})

      conn2 =
        conn |> authed(osh) |> post(~p"/api/faculties", %{name: "Faculty of Y", code: "FOY"})

      assert json_response(conn2, 403)
    end

    test "no token gets 401", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/faculties"), 401)
    end
  end

  describe "departments" do
    test "any authenticated role can list", %{conn: conn} do
      department_fixture()

      for role <- SalvorionWeb.RBAC.roles() do
        user = user_fixture(%{role: role})
        conn = conn |> authed(user) |> get(~p"/api/departments")
        assert %{"data" => [_ | _]} = json_response(conn, 200)
      end
    end

    test "admin creates a department; warden gets 403", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn1 =
        conn |> authed(admin) |> post(~p"/api/departments", %{name: "Dept A", code: "DEPT_A"})

      assert %{"data" => %{"code" => "DEPT_A"}} = json_response(conn1, 201)

      warden = user_fixture(%{role: "warden"})

      conn2 =
        conn |> authed(warden) |> post(~p"/api/departments", %{name: "Dept B", code: "DEPT_B"})

      assert json_response(conn2, 403)
    end
  end

  describe "programmes" do
    test "any authenticated role can list", %{conn: conn} do
      programme_fixture()

      for role <- SalvorionWeb.RBAC.roles() do
        user = user_fixture(%{role: role})
        conn = conn |> authed(user) |> get(~p"/api/programmes")
        assert %{"data" => [_ | _]} = json_response(conn, 200)
      end
    end

    test "admin creates a programme; report_viewer gets 403", %{conn: conn} do
      {:ok, faculty} = Salvorion.Organisation.create_faculty(%{name: "Faculty of Z", code: "FOZ"})
      admin = user_fixture(%{role: "admin"})

      conn1 =
        conn
        |> authed(admin)
        |> post(~p"/api/programmes", %{
          name: "Programme A",
          code: "PROG_A",
          faculty_id: faculty.id
        })

      assert %{"data" => %{"code" => "PROG_A"}} = json_response(conn1, 201)

      viewer = user_fixture(%{role: "report_viewer"})

      conn2 =
        conn
        |> authed(viewer)
        |> post(~p"/api/programmes", %{
          name: "Programme B",
          code: "PROG_B",
          faculty_id: faculty.id
        })

      assert json_response(conn2, 403)
    end
  end
end
