defmodule SalvorionWeb.AccountabilityReadsControllersTest do
  @moduledoc """
  Roll-call, contradiction resolution and the dashboard reads (Task 8).
  """
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.{Accountability, Accounts, Activations, Locations}

  defp scan!(activation, person, actor) do
    {:ok, _event, status} =
      Accountability.ingest_event(
        %{
          client_uuid: Ecto.UUID.generate(),
          activation_id: activation.id,
          person_id: person.id,
          kind: "scanned",
          status: "present",
          client_timestamp: DateTime.utc_now()
        },
        actor: actor
      )

    status
  end

  describe "GET /api/activations/:id/roll-call" do
    test "a warden sees their own scope; there is no user_id parameter that could name another warden",
         %{conn: conn} do
      zone = zone_fixture()
      {:ok, area} = Locations.create_area(%{name: "RC Area", zone_id: zone.id})
      dept = department_fixture()
      {:ok, _} = Locations.link_department_to_area(dept, area)
      staff = person_fixture(%{type: "staff", primary_department_id: dept.id})

      officer = user_fixture(%{role: "osh_officer"})
      warden = user_fixture(%{role: "warden"})
      other_warden = user_fixture(%{role: "warden"})
      {:ok, _} = Accounts.assign_warden(warden.id, {:zone, zone.id}, {~D[2020-01-01], nil})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      conn1 =
        conn
        |> authed(warden)
        |> get(~p"/api/activations/#{activation.id}/roll-call?user_id=#{other_warden.id}")

      assert %{"data" => %{"unaccounted" => rows, "counts" => %{"unaccounted" => 1}}} =
               json_response(conn1, 200)

      assert [%{"person_id" => id}] = rows
      assert id == staff.id
    end

    test "admin and osh_officer get 403 (this route is warden ONLY; they use the zone drill-down)",
         %{
           conn: conn
         } do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      admin = user_fixture(%{role: "admin"})

      assert json_response(
               conn |> authed(admin) |> get(~p"/api/activations/#{activation.id}/roll-call"),
               403
             )

      assert json_response(
               conn |> authed(officer) |> get(~p"/api/activations/#{activation.id}/roll-call"),
               403
             )
    end

    test "a warden with no assignment gets 403", %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      warden = user_fixture(%{role: "warden"})

      conn = conn |> authed(warden) |> get(~p"/api/activations/#{activation.id}/roll-call")
      assert json_response(conn, 403)
    end
  end

  describe "GET /api/activations/:id/zones/:zone_id/roll-call" do
    test "admin and osh_officer can drill into any zone; warden gets 403", %{conn: conn} do
      zone = zone_fixture()
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      admin = user_fixture(%{role: "admin"})

      assert json_response(
               conn
               |> authed(admin)
               |> get(~p"/api/activations/#{activation.id}/zones/#{zone.id}/roll-call"),
               200
             )

      warden = user_fixture(%{role: "warden"})

      assert json_response(
               conn
               |> authed(warden)
               |> get(~p"/api/activations/#{activation.id}/zones/#{zone.id}/roll-call"),
               403
             )
    end
  end

  describe "POST /api/activations/:id/people/:person_id/resolve-contradiction" do
    test "the warden who flagged it, or admin/osh_officer, can resolve it; report_viewer gets 403",
         %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      person = person_fixture()
      scan!(activation, person, officer)

      {:ok, _, _} =
        Accountability.ingest_event(
          %{
            client_uuid: Ecto.UUID.generate(),
            activation_id: activation.id,
            person_id: person.id,
            kind: "roll_call",
            status: "absent",
            client_timestamp: DateTime.utc_now()
          },
          actor: officer
        )

      assert Accountability.count_open_contradictions(activation.id) == 1

      conn =
        conn
        |> authed(officer)
        |> post(~p"/api/activations/#{activation.id}/people/#{person.id}/resolve-contradiction")

      assert %{"data" => %{"status" => "present", "contradiction_resolved_at" => at}} =
               json_response(conn, 200)

      refute is_nil(at)

      viewer = user_fixture(%{role: "report_viewer"})

      conn2 =
        build_conn()
        |> authed(viewer)
        |> post(~p"/api/activations/#{activation.id}/people/#{person.id}/resolve-contradiction")

      assert json_response(conn2, 403)
    end

    test "no open contradiction is a 409", %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      person = person_fixture()
      scan!(activation, person, officer)

      conn =
        conn
        |> authed(officer)
        |> post(~p"/api/activations/#{activation.id}/people/#{person.id}/resolve-contradiction")

      assert json_response(conn, 409)
    end
  end

  describe "dashboard reads" do
    test "admin, osh_officer, report_viewer can read all five; warden gets 403 on all five", %{
      conn: conn
    } do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      routes = [
        ~p"/api/activations/#{activation.id}/dashboard/summary",
        ~p"/api/activations/#{activation.id}/dashboard/departments",
        ~p"/api/activations/#{activation.id}/dashboard/faculties",
        ~p"/api/activations/#{activation.id}/dashboard/zones",
        ~p"/api/activations/#{activation.id}/dashboard/unaccounted"
      ]

      for role <- ["admin", "osh_officer", "report_viewer"], route <- routes do
        user = user_fixture(%{role: role})
        assert json_response(conn |> authed(user) |> get(route), 200)
      end

      warden = user_fixture(%{role: "warden"})

      for route <- routes do
        assert json_response(conn |> authed(warden) |> get(route), 403)
      end
    end

    test "unaccounted list accepts department_id/faculty_id/zone_id/type filters, ignores an unknown one",
         %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})
      dept = department_fixture()
      staff = person_fixture(%{type: "staff", primary_department_id: dept.id})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      conn1 =
        conn
        |> authed(officer)
        |> get(
          ~p"/api/activations/#{activation.id}/dashboard/unaccounted?department_id=#{dept.id}"
        )

      assert %{"data" => [%{"person_id" => id}]} = json_response(conn1, 200)
      assert id == staff.id

      conn2 =
        conn
        |> authed(officer)
        |> get(~p"/api/activations/#{activation.id}/dashboard/unaccounted?bogus_filter=whatever")

      assert %{"data" => data} = json_response(conn2, 200)
      assert is_list(data)
    end
  end
end
