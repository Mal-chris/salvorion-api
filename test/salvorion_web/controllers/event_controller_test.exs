defmodule SalvorionWeb.EventControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.Activations

  defp event_attrs(person, overrides \\ %{}) do
    Map.merge(
      %{
        client_uuid: Ecto.UUID.generate(),
        person_id: person.id,
        kind: "scanned",
        status: "present",
        client_timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      },
      overrides
    )
  end

  describe "POST /api/activations/:id/events" do
    test "admin, osh_officer and warden can ingest a scan; report_viewer gets 403", %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      for role <- ["admin", "osh_officer", "warden"] do
        user = user_fixture(%{role: role})
        person = person_fixture()

        conn =
          conn
          |> authed(user)
          |> post(~p"/api/activations/#{activation.id}/events", event_attrs(person))

        assert %{"data" => %{"status" => "present", "duplicate" => false}} =
                 json_response(conn, 201)
      end

      viewer = user_fixture(%{role: "report_viewer"})
      person = person_fixture()

      conn =
        conn
        |> authed(viewer)
        |> post(~p"/api/activations/#{activation.id}/events", event_attrs(person))

      assert json_response(conn, 403)
    end

    test "the same client_uuid twice returns the existing event as a duplicate, 200 not 201", %{
      conn: conn
    } do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      person = person_fixture()
      attrs = event_attrs(person)

      conn1 = conn |> authed(officer) |> post(~p"/api/activations/#{activation.id}/events", attrs)
      assert %{"data" => %{"id" => id1}} = json_response(conn1, 201)

      conn2 = conn |> authed(officer) |> post(~p"/api/activations/#{activation.id}/events", attrs)
      assert %{"data" => %{"id" => id2, "duplicate" => true}} = json_response(conn2, 200)
      assert id1 == id2
    end

    test "an unknown id_number is a 404, not a 500", %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      attrs = %{
        client_uuid: Ecto.UUID.generate(),
        id_number: "NOPE-000",
        kind: "scanned",
        status: "present",
        client_timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
      }

      conn = conn |> authed(officer) |> post(~p"/api/activations/#{activation.id}/events", attrs)
      assert json_response(conn, 404)
    end

    test "a scheduled (not yet started) activation returns 409", %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, scheduled} =
        Activations.schedule_activation(
          %{activation_type: "drill", started_at: DateTime.utc_now()}, actor: officer)

      person = person_fixture()

      conn =
        conn
        |> authed(officer)
        |> post(~p"/api/activations/#{scheduled.id}/events", event_attrs(person))

      assert json_response(conn, 409)
    end

    test "override by a warden is 403 — the role check inside ingest_event/2 is not bypassed by the route",
         %{
           conn: conn
         } do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      warden = user_fixture(%{role: "warden"})
      person = person_fixture()

      conn =
        conn
        |> authed(warden)
        |> post(
          ~p"/api/activations/#{activation.id}/events",
          event_attrs(person, %{kind: "override", status: "excused", note: "phoned"})
        )

      assert json_response(conn, 403)
    end
  end
end
