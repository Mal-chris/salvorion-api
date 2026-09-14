defmodule Salvorion.Reporting.Workers.GenerateReportWorkerTest do
  # async: false — start_activation/2's advisory lock, plus this worker
  # makes a real HTTP call to the shared Gotenberg container.
  use Salvorion.DataCase, async: false
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

  test "renders the PDF, marks the run generated, and enqueues one DeliverReportWorker per active recipient",
       %{officer: officer, activation: activation} do
    {:ok, recipient} =
      Reporting.create_report_recipient(%{name: "HR", email: "hr@example.test"}, actor: officer)

    assert :ok = perform_job(GenerateReportWorker, %{activation_id: activation.id})

    assert [run] = Reporting.list_report_runs(activation.id)
    assert run.status == "generated"
    assert run.pdf_path
    assert File.exists?(run.pdf_path)
    assert run.generated_at

    assert_enqueued(
      worker: DeliverReportWorker,
      args: %{report_run_id: run.id, report_recipient_id: recipient.id}
    )
  end

  test "zero active recipients: the run is marked delivered (vacuously) and the activation is reported",
       %{activation: activation} do
    assert Reporting.list_report_recipients(active_only: true) == []

    assert :ok = perform_job(GenerateReportWorker, %{activation_id: activation.id})

    assert [run] = Reporting.list_report_runs(activation.id)
    assert run.status == "delivered"
    assert run.deliveries == []

    assert Activations.get_activation!(activation.id).status == "reported"

    assert Enum.any?(
             Salvorion.Audit.list_audit_logs(entity_type: "report_run", entity_id: run.id),
             &(&1.action == "report.no_recipients_configured")
           )
  end
end
