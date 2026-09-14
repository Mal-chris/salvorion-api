defmodule Salvorion.ReportingTest do
  # async: false — start_activation/2 serialises on a single fixed
  # advisory-lock key (see ActivationsTest), and render_report_pdf/1's
  # test makes a real HTTP call to the shared Gotenberg container.
  use Salvorion.DataCase, async: false
  use Oban.Testing, repo: Salvorion.Repo

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.{Accountability, Activations, Audit, Reporting}
  alias Salvorion.Reporting.Workers.GenerateReportWorker

  setup do
    officer = user_fixture(%{role: "osh_officer"})
    %{officer: officer}
  end

  defp closed_activation(officer, type \\ "drill") do
    {:ok, activation} = Activations.start_activation(%{activation_type: type}, actor: officer)
    {:ok, activation} = Activations.close_activation(activation, actor: officer)
    activation
  end

  defp manual_event!(activation, person, recorder) do
    {:ok, event, _status} =
      Accountability.ingest_event(
        %{
          client_uuid: Ecto.UUID.generate(),
          activation_id: activation.id,
          person_id: person.id,
          kind: "manual",
          status: "present",
          client_timestamp: DateTime.utc_now()
        },
        actor: recorder
      )

    event
  end

  # ---------------------------------------------------------------------------
  # Task 2: report recipients
  # ---------------------------------------------------------------------------

  describe "report recipients" do
    test "create_report_recipient/2 creates and audits", %{officer: officer} do
      assert {:ok, recipient} =
               Reporting.create_report_recipient(
                 %{name: "HR", email: "hr@example.test"},
                 actor: officer
               )

      assert recipient.active

      assert [log] =
               Audit.list_audit_logs(entity_type: "report_recipient", entity_id: recipient.id)

      assert log.action == "report_recipient.created"
      assert log.actor_user_id == officer.id
    end

    test "list_report_recipients/1 defaults to active_only: true", %{officer: officer} do
      {:ok, active} =
        Reporting.create_report_recipient(%{name: "Active", email: "a@example.test"},
          actor: officer
        )

      {:ok, inactive} =
        Reporting.create_report_recipient(%{name: "Inactive", email: "i@example.test"},
          actor: officer
        )

      {:ok, _} = Reporting.deactivate_report_recipient(inactive, actor: officer)

      ids = Reporting.list_report_recipients() |> Enum.map(& &1.id)
      assert active.id in ids
      refute inactive.id in ids

      all_ids = Reporting.list_report_recipients(active_only: false) |> Enum.map(& &1.id)
      assert active.id in all_ids
      assert inactive.id in all_ids
    end

    test "update_report_recipient/3 updates and audits", %{officer: officer} do
      {:ok, recipient} =
        Reporting.create_report_recipient(%{name: "HR", email: "hr@example.test"}, actor: officer)

      assert {:ok, updated} =
               Reporting.update_report_recipient(recipient, %{name: "Human Resources"},
                 actor: officer
               )

      assert updated.name == "Human Resources"

      assert Enum.any?(
               Audit.list_audit_logs(entity_type: "report_recipient", entity_id: recipient.id),
               &(&1.action == "report_recipient.updated")
             )
    end

    test "deactivate_report_recipient/2 sets active: false, never deletes", %{officer: officer} do
      {:ok, recipient} =
        Reporting.create_report_recipient(%{name: "HR", email: "hr@example.test"}, actor: officer)

      assert {:ok, deactivated} = Reporting.deactivate_report_recipient(recipient, actor: officer)
      assert deactivated.active == false
      assert Reporting.get_report_recipient!(recipient.id)
    end
  end

  # ---------------------------------------------------------------------------
  # Task 3: compile_report_data/1
  # ---------------------------------------------------------------------------

  describe "compile_report_data/1" do
    test "includes every FR-REP-02 field, including a manual event", %{officer: officer} do
      dept = department_fixture()
      person = person_fixture(%{primary_department_id: dept.id})

      {:ok, activation} = Activations.start_activation(%{activation_type: "real"}, actor: officer)
      event = manual_event!(activation, person, officer)
      {:ok, activation} = Activations.close_activation(activation, actor: officer)

      data = Reporting.compile_report_data(activation)

      assert data.activation.id == activation.id
      assert data.activation.activation_type == "real"
      assert data.activation.scope == "campus"
      assert data.activation.started_at == activation.started_at
      assert data.activation.closed_at == activation.closed_at

      assert %{expected: _, present: _, absent: _, unaccounted: _} = data.summary
      assert is_list(data.by_department)
      assert is_list(data.by_faculty)
      assert is_list(data.unaccounted)

      assert [manual] = data.manual_events
      assert manual.event_id == event.id
      assert manual.person_id == person.id
      assert manual.recorded_by_email == officer.email
    end

    test "has no side effects — calling it twice returns the same data", %{officer: officer} do
      activation = closed_activation(officer)

      assert Reporting.compile_report_data(activation) ==
               Reporting.compile_report_data(activation)
    end
  end

  describe "format_rate/1" do
    test "nil is n/a, a float is a rounded percentage" do
      assert Reporting.format_rate(nil) == "n/a"
      assert Reporting.format_rate(0.5) == "50.0%"
      assert Reporting.format_rate(1.0) == "100.0%"
      assert Reporting.format_rate(1 / 3) == "33.3%"
    end
  end

  # ---------------------------------------------------------------------------
  # Task 4: render_report_pdf/1, against the real running Gotenberg
  # ---------------------------------------------------------------------------

  describe "render_report_pdf/1" do
    test "renders a genuine PDF via the running Gotenberg container", %{officer: officer} do
      activation = closed_activation(officer)

      assert {:ok, pdf} = Reporting.render_report_pdf(activation)
      assert is_binary(pdf)
      assert byte_size(pdf) > 1000
      assert String.starts_with?(pdf, "%PDF")
    end
  end

  # ---------------------------------------------------------------------------
  # Task 7: regenerate_report/2
  # ---------------------------------------------------------------------------

  describe "regenerate_report/2" do
    test "enqueues a GenerateReportWorker job and audits report.regenerate_requested", %{
      officer: officer
    } do
      activation = closed_activation(officer)

      assert {:ok, _job} = Reporting.regenerate_report(activation, actor: officer)

      assert_enqueued(worker: GenerateReportWorker, args: %{activation_id: activation.id})

      assert Enum.any?(
               Audit.list_audit_logs(entity_type: "activation", entity_id: activation.id),
               &(&1.action == "report.regenerate_requested")
             )
    end

    test "does not revert a reported activation's status", %{officer: officer} do
      activation = closed_activation(officer)
      {:ok, activation} = Activations.mark_activation_reported(activation)

      assert {:ok, _job} = Reporting.regenerate_report(activation)

      assert Activations.get_activation!(activation.id).status == "reported"
    end
  end
end
