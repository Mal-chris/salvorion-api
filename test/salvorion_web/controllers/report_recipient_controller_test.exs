defmodule SalvorionWeb.ReportRecipientControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Reporting

  describe "POST /api/report-recipients" do
    test "admin and osh_officer can create one", %{conn: conn} do
      for role <- ["admin", "osh_officer"] do
        actor = user_fixture(%{role: role})

        conn =
          conn
          |> authed(actor)
          |> post(~p"/api/report-recipients", %{name: "HR", email: "hr-#{role}@example.test"})

        assert %{"data" => %{"name" => "HR", "active" => true}} = json_response(conn, 201)
      end
    end

    test "warden gets 403", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})

      conn =
        conn
        |> authed(warden)
        |> post(~p"/api/report-recipients", %{name: "HR", email: "hr@example.test"})

      assert json_response(conn, 403)
    end
  end

  describe "GET /api/report-recipients" do
    test "defaults to active only, ?active_only=false includes deactivated", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      {:ok, active} =
        Reporting.create_report_recipient(%{name: "Active", email: "a@example.test"})

      {:ok, inactive} =
        Reporting.create_report_recipient(%{name: "Inactive", email: "i@example.test"})

      {:ok, _} = Reporting.deactivate_report_recipient(inactive)

      conn1 = conn |> authed(admin) |> get(~p"/api/report-recipients")
      ids1 = json_response(conn1, 200)["data"] |> Enum.map(& &1["id"])
      assert active.id in ids1
      refute inactive.id in ids1

      conn2 = conn |> authed(admin) |> get(~p"/api/report-recipients?active_only=false")
      ids2 = json_response(conn2, 200)["data"] |> Enum.map(& &1["id"])
      assert active.id in ids2
      assert inactive.id in ids2
    end

    test "warden gets 403", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})
      conn = conn |> authed(warden) |> get(~p"/api/report-recipients")
      assert json_response(conn, 403)
    end
  end

  describe "PATCH /api/report-recipients/:id" do
    test "admin can update", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      {:ok, recipient} =
        Reporting.create_report_recipient(%{name: "HR", email: "hr@example.test"})

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/report-recipients/#{recipient.id}", %{name: "Human Resources"})

      assert %{"data" => %{"name" => "Human Resources"}} = json_response(conn, 200)
    end

    test "warden gets 403", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})

      {:ok, recipient} =
        Reporting.create_report_recipient(%{name: "HR", email: "hr@example.test"})

      conn =
        conn
        |> authed(warden)
        |> patch(~p"/api/report-recipients/#{recipient.id}", %{name: "Nope"})

      assert json_response(conn, 403)
    end
  end
end
