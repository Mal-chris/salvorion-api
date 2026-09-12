defmodule SalvorionWeb.ActivationControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Activations

  describe "POST /api/activations" do
    test "osh_officer starts one; admin gets 403 (deliberately not admin — Prompt 5)", %{
      conn: conn
    } do
      osh = user_fixture(%{role: "osh_officer"})
      conn1 = conn |> authed(osh) |> post(~p"/api/activations", %{activation_type: "drill"})
      assert %{"data" => %{"status" => "active", "scope" => "campus"}} = json_response(conn1, 201)

      admin = user_fixture(%{role: "admin"})
      conn2 = conn |> authed(admin) |> post(~p"/api/activations", %{activation_type: "drill"})
      assert json_response(conn2, 403)
    end

    test "a zone conflict is a 409 with a message", %{conn: conn} do
      osh = user_fixture(%{role: "osh_officer"})
      {:ok, _} = Activations.start_activation(%{activation_type: "real"}, actor: osh)

      conn = conn |> authed(osh) |> post(~p"/api/activations", %{activation_type: "drill"})
      assert %{"error" => message} = json_response(conn, 409)
      assert message =~ "conflicts with"
    end
  end

  describe "PATCH /api/activations/:id/close and POST /:id/start" do
    test "osh_officer starts a scheduled activation and closes it; warden gets 403 on both", %{
      conn: conn
    } do
      osh = user_fixture(%{role: "osh_officer"})

      {:ok, scheduled} =
        Activations.schedule_activation(
          %{activation_type: "drill", started_at: DateTime.utc_now()}, actor: osh)

      start_conn = conn |> authed(osh) |> post(~p"/api/activations/#{scheduled.id}/start")
      assert %{"data" => %{"status" => "active"}} = json_response(start_conn, 200)

      close_conn = conn |> authed(osh) |> patch(~p"/api/activations/#{scheduled.id}/close")
      assert %{"data" => %{"status" => "closed"}} = json_response(close_conn, 200)

      warden = user_fixture(%{role: "warden"})

      {:ok, scheduled2} =
        Activations.schedule_activation(
          %{activation_type: "drill", started_at: DateTime.utc_now()}, actor: osh)

      assert json_response(
               conn |> authed(warden) |> post(~p"/api/activations/#{scheduled2.id}/start"),
               403
             )

      assert json_response(
               conn |> authed(warden) |> patch(~p"/api/activations/#{scheduled2.id}/close"),
               403
             )
    end
  end

  describe "GET /api/activations" do
    test "admin, osh_officer and report_viewer can list; warden gets 403", %{conn: conn} do
      for role <- ["admin", "osh_officer", "report_viewer"] do
        user = user_fixture(%{role: role})
        assert json_response(conn |> authed(user) |> get(~p"/api/activations"), 200)
      end

      warden = user_fixture(%{role: "warden"})
      assert json_response(conn |> authed(warden) |> get(~p"/api/activations"), 403)
    end
  end

  describe "GET /api/activations/:id" do
    test "admin, osh_officer, report_viewer AND warden can view a single activation", %{
      conn: conn
    } do
      osh = user_fixture(%{role: "osh_officer"})
      {:ok, activation} = Activations.start_activation(%{activation_type: "drill"}, actor: osh)

      for role <- SalvorionWeb.RBAC.roles() do
        user = user_fixture(%{role: role})
        conn = conn |> authed(user) |> get(~p"/api/activations/#{activation.id}")
        assert %{"data" => %{"id" => id}} = json_response(conn, 200)
        assert id == activation.id
      end
    end

    test "an unknown id is 404", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      conn = conn |> authed(admin)

      # Activations.get_activation!/1 raises Ecto.NoResultsError for a
      # missing row; phoenix_ecto maps that to 404 via Plug.Exception in a
      # real request (curl-verified), but Phoenix.ConnTest dispatches
      # in-process and re-raises rather than auto-converting, so the test
      # has to assert the conversion explicitly.
      assert_error_sent(404, fn -> get(conn, ~p"/api/activations/#{Ecto.UUID.generate()}") end)
    end
  end
end
