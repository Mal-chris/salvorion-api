defmodule Salvorion.Reporting.Workers.DeliverReportWorkerTest do
  # async: false — start_activation/2's advisory lock, plus this suite
  # makes real HTTP calls to the shared Gotenberg container via
  # GenerateReportWorker in each test's own setup.
  use Salvorion.DataCase, async: false
  use Oban.Testing, repo: Salvorion.Repo

  import Salvorion.AccountsFixtures
  import Swoosh.TestAssertions

  alias Salvorion.{Activations, Reporting}
  alias Salvorion.Reporting.Workers.{DeliverReportWorker, GenerateReportWorker}

  # ReportRecipients are global, not scoped per activation, so recipient
  # creation is deliberately kept inside each test (not a shared
  # `setup`) — a recipient created for one test must never bleed into
  # another test's "how many deliveries got created" or "is the
  # activation reported yet" assertions.
  defp closed_activation(officer) do
    {:ok, activation} = Activations.start_activation(%{activation_type: "drill"}, actor: officer)
    {:ok, activation} = Activations.close_activation(activation, actor: officer)
    activation
  end

  test "sends the email, marks the delivery sent, and (as the only recipient) reports the activation" do
    officer = user_fixture(%{role: "osh_officer"})
    activation = closed_activation(officer)

    {:ok, recipient} =
      Reporting.create_report_recipient(%{name: "HR", email: "hr@example.test"}, actor: officer)

    assert :ok = perform_job(GenerateReportWorker, %{activation_id: activation.id})
    [run] = Reporting.list_report_runs(activation.id)

    assert :ok =
             perform_job(DeliverReportWorker, %{
               report_run_id: run.id,
               report_recipient_id: recipient.id
             })

    [reloaded_run] = Reporting.list_report_runs(activation.id)
    assert reloaded_run.status == "delivered"

    assert [delivery] = reloaded_run.deliveries
    assert delivery.delivery_status == "sent"
    assert delivery.delivered_at
    assert delivery.report_recipient.id == recipient.id

    assert Activations.get_activation!(activation.id).status == "reported"

    assert_email_sent(fn email ->
      assert email.to == [{recipient.name, recipient.email}]
      assert email.subject =~ "Drill"
      assert [attachment] = email.attachments
      assert attachment.filename == "activation-report-#{activation.id}.pdf"
      assert attachment.content_type == "application/pdf"
    end)
  end

  test "with two recipients, the activation is only reported once both deliveries are terminal" do
    officer = user_fixture(%{role: "osh_officer"})
    activation = closed_activation(officer)

    # Both recipients must exist BEFORE generation, so GenerateReportWorker
    # creates a pending ReportDelivery row for each of them up front.
    {:ok, recipient1} =
      Reporting.create_report_recipient(%{name: "HR", email: "hr2@example.test"})

    {:ok, recipient2} =
      Reporting.create_report_recipient(%{name: "Dean", email: "dean@example.test"})

    assert :ok = perform_job(GenerateReportWorker, %{activation_id: activation.id})
    [run] = Reporting.list_report_runs(activation.id)
    assert length(run.deliveries) == 2

    assert :ok =
             perform_job(DeliverReportWorker, %{
               report_run_id: run.id,
               report_recipient_id: recipient1.id
             })

    # Only one of two deliveries settled — not reported yet.
    assert Activations.get_activation!(activation.id).status == "closed"

    assert :ok =
             perform_job(DeliverReportWorker, %{
               report_run_id: run.id,
               report_recipient_id: recipient2.id
             })

    assert Activations.get_activation!(activation.id).status == "reported"
  end
end
