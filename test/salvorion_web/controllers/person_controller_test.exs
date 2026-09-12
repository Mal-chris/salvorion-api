defmodule SalvorionWeb.PersonControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  describe "GET /api/people" do
    test "admin, osh_officer and warden can list; report_viewer gets 403", %{conn: conn} do
      person_fixture()

      for role <- ["admin", "osh_officer", "warden"] do
        user = user_fixture(%{role: role})
        conn = conn |> authed(user) |> get(~p"/api/people")
        assert %{"data" => [_ | _], "meta" => %{"total" => total}} = json_response(conn, 200)
        assert total >= 1
      end

      viewer = user_fixture(%{role: "report_viewer"})
      assert json_response(conn |> authed(viewer) |> get(~p"/api/people"), 403)
    end

    test "no token gets 401", %{conn: conn} do
      assert json_response(get(conn, ~p"/api/people"), 401)
    end

    test "is paginated via limit/offset, and an unknown filter is ignored rather than misapplied",
         %{
           conn: conn
         } do
      admin = user_fixture(%{role: "admin"})
      for _ <- 1..3, do: person_fixture(%{type: "staff"})

      page1 = conn |> authed(admin) |> get(~p"/api/people?type=staff&limit=2&offset=0")

      assert %{"data" => data1, "meta" => %{"total" => total, "limit" => 2, "offset" => 0}} =
               json_response(page1, 200)

      assert length(data1) == 2
      assert total >= 3

      page2 = conn |> authed(admin) |> get(~p"/api/people?type=staff&limit=2&offset=2")
      assert %{"data" => data2} = json_response(page2, 200)
      refute Enum.map(data1, & &1["id"]) == Enum.map(data2, & &1["id"])

      # a typo'd filter name is ignored, not a 500 and not silently misapplied
      ignored = conn |> authed(admin) |> get(~p"/api/people?tpye=staff")
      assert %{"data" => _} = json_response(ignored, 200)
    end
  end

  describe "GET /api/people/:id" do
    test "returns the person", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      person = person_fixture()

      conn = conn |> authed(admin) |> get(~p"/api/people/#{person.id}")
      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == person.id
    end
  end

  describe "GET /api/people/lookup" do
    test "resolves a known id_number", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      person = person_fixture(%{id_number: "LOOKUP-1"})

      conn = conn |> authed(admin) |> get(~p"/api/people/lookup?id_number=LOOKUP-1")
      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == person.id
    end

    test "a nonexistent id_number is 404, not 200 with an empty body", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      conn = conn |> authed(admin) |> get(~p"/api/people/lookup?id_number=NOPE-000")
      assert json_response(conn, 404)
    end
  end
end
