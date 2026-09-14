defmodule SalvorionWeb.ReportControllerTest do
  # async: false — start_activation/2's advisory lock (see
  # ActivationsTest), and this suite renders real PDFs via Gotenberg.
  use SalvorionWeb.ConnCase, async: false
  use Oban.Testing, repo: Salvorion.Repo

  import Salvorion.AccountsFixtures

  alias Salvorion.{Activations, Reporting}
  alias Salvorion.Reporting.Workers.{DeliverReportWorker, GenerateReportWorker}

  setup do
    officer = user_fixture(%{role: "osh_officer"})
    {:ok, activation} = Activations.start_activation(%{activation_type: "drill"}, actor: officer)
    {:ok, activation} = Activations.close_activation(activation, actor: officer)
    %{officer: officer, activation: activation}
  end

  defp generated_run(activation, recipient_actor) do
    {:ok, recipient} =
      Reporting.create_report_recipient(%{name: "R1", email: "r1@example.test"},
        actor: recipient_actor
      )

    assert :ok = perform_job(GenerateReportWorker, %{activation_id: activation.id})
    [run] = Reporting.list_report_runs(activation.id)

    assert :ok =
             perform_job(DeliverReportWorker, %{
               report_run_id: run.id,
               report_recipient_id: recipient.id
             })

    Reporting.get_report_run(activation.id, run.id)
  end

  @task8_requests [
    {"POST", "/api/report-recipients", %{name: "X", email: "x@example.test"}},
    {"GET", "/api/report-recipients", nil},
    {"PATCH", "/api/report-recipients/00000000-0000-0000-0000-000000000000", %{name: "X"}}
  ]

  describe "RBAC: a warden may not use any Task 8 route" do
    test "report-recipient routes are 403 for warden", %{conn: conn} do
      warden = user_fixture(%{role: "warden"})

      for {method, path, body} <- @task8_requests do
        conn =
          case method do
            "POST" -> conn |> authed(warden) |> post(path, body)
            "GET" -> conn |> authed(warden) |> get(path)
            "PATCH" -> conn |> authed(warden) |> patch(path, body)
          end

        assert json_response(conn, 403), "expected 403 for #{method} #{path}"
      end
    end

    test "activation report routes are 403 for warden", %{conn: conn, activation: activation} do
      warden = user_fixture(%{role: "warden"})

      conn1 = conn |> authed(warden) |> get(~p"/api/activations/#{activation.id}/reports")
      assert json_response(conn1, 403)

      conn2 =
        conn
        |> authed(warden)
        |> get(
          ~p"/api/activations/#{activation.id}/reports/00000000-0000-0000-0000-000000000000/download"
        )

      assert json_response(conn2, 403)

      conn3 =
        conn
        |> authed(warden)
        |> post(~p"/api/activations/#{activation.id}/reports/regenerate", %{})

      assert json_response(conn3, 403)
    end
  end

  describe "GET /api/activations/:id/reports" do
    test "report_viewer sees runs newest first, with deliveries", %{
      conn: conn,
      activation: activation,
      officer: officer
    } do
      run = generated_run(activation, officer)
      viewer = user_fixture(%{role: "report_viewer"})

      conn = conn |> authed(viewer) |> get(~p"/api/activations/#{activation.id}/reports")
      assert %{"data" => [returned]} = json_response(conn, 200)
      assert returned["id"] == run.id
      assert [delivery] = returned["deliveries"]
      assert delivery["delivery_status"] == "sent"
      assert delivery["recipient_email"] == "r1@example.test"
    end
  end

  describe "GET /api/activations/:id/reports/:run_id/download" do
    test "streams the exact PDF bytes for a generated run", %{
      conn: conn,
      activation: activation,
      officer: officer
    } do
      run = generated_run(activation, officer)
      viewer = user_fixture(%{role: "report_viewer"})

      conn =
        conn
        |> authed(viewer)
        |> get(~p"/api/activations/#{activation.id}/reports/#{run.id}/download")

      assert conn.status == 200
      assert conn.resp_body == File.read!(run.pdf_path)
      assert get_resp_header(conn, "content-type") == ["application/pdf"]
    end

    test "404 :report_not_ready for a pending run, not a broken download", %{
      conn: conn,
      activation: activation
    } do
      {:ok, pending_run} = Reporting.create_report_run(activation.id)
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> authed(admin)
        |> get(~p"/api/activations/#{activation.id}/reports/#{pending_run.id}/download")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/activations/:id/reports/regenerate" do
    test "admin/osh_officer can regenerate; creates a new ReportRun, first untouched", %{
      conn: conn,
      activation: activation,
      officer: officer
    } do
      first_run = generated_run(activation, officer)

      regenerate_conn =
        conn
        |> authed(officer)
        |> post(~p"/api/activations/#{activation.id}/reports/regenerate", %{})

      assert json_response(regenerate_conn, 202)

      assert :ok = perform_job(GenerateReportWorker, %{activation_id: activation.id})

      runs = Reporting.list_report_runs(activation.id)
      assert length(runs) == 2

      assert DateTime.compare(Enum.at(runs, 0).inserted_at, Enum.at(runs, 1).inserted_at) in [
               :gt,
               :eq
             ]

      assert Reporting.get_report_run(activation.id, first_run.id).status == "delivered"

      list_conn = conn |> authed(officer) |> get(~p"/api/activations/#{activation.id}/reports")
      ids = json_response(list_conn, 200)["data"] |> Enum.map(& &1["id"])
      assert length(ids) == 2
      assert first_run.id in ids
    end
  end
end
