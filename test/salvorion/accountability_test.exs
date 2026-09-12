defmodule Salvorion.AccountabilityTest do
  # async: false — the concurrency test at the bottom switches the
  # sandbox to :auto mode, and start_activation/2 serialises on one
  # advisory-lock key anyway.
  use Salvorion.DataCase, async: false

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.{Accountability, Activations, Audit, Locations, Settings}
  alias Salvorion.Accountability.{AccountabilityEvent, ExpectedPresence, PersonStatus}

  setup do
    officer = user_fixture(%{role: "osh_officer"})
    %{officer: officer}
  end

  defp start_campus(officer) do
    {:ok, activation} = Activations.start_activation(%{activation_type: "drill"}, actor: officer)
    activation
  end

  defp event_attrs(activation, person, overrides) do
    Map.merge(
      %{
        client_uuid: Ecto.UUID.generate(),
        activation_id: activation.id,
        person_id: person.id,
        kind: "scanned",
        status: "present",
        client_timestamp: DateTime.utc_now()
      },
      Map.new(overrides)
    )
  end

  defp ingest!(activation, person, recorder, overrides \\ []) do
    {:ok, event, status} =
      Accountability.ingest_event(event_attrs(activation, person, overrides), actor: recorder)

    {event, status}
  end

  # ---------------------------------------------------------------------------
  # Expected presence
  # ---------------------------------------------------------------------------

  describe "initialise_for_activation/1 (via start_activation)" do
    test "campus scope, signed_in_only: every staff expected, no students, idempotent", %{
      officer: officer
    } do
      staff = for _ <- 1..3, do: person_fixture(%{type: "staff"})
      _student = person_fixture(%{type: "student"})
      _visitor = person_fixture(%{type: "visitor", source: "visitor_registration"})

      activation = start_campus(officer)

      expected = Repo.all(from ep in ExpectedPresence, where: ep.activation_id == ^activation.id)
      assert length(expected) == 3
      assert Enum.all?(expected, &(&1.rule_applied == "staff_by_location"))
      assert MapSet.new(expected, & &1.person_id) == MapSet.new(staff, & &1.id)

      assert Accountability.count_statuses(activation.id) == %{
               present: 0,
               absent: 0,
               excused: 0,
               unaccounted: 3
             }

      # rerun: no duplicates, nothing reset
      assert {:ok, %{expected: 0}} = Accountability.initialise_for_activation(activation)
      assert Repo.aggregate(ExpectedPresence, :count) == 3
      assert Repo.aggregate(PersonStatus, :count) == 3
    end

    test "all_enrolled expects every student too; timetable_expected raises", %{
      officer: officer
    } do
      person_fixture(%{type: "staff"})
      person_fixture(%{type: "student"})
      person_fixture(%{type: "student"})

      {:ok, _} = Settings.put_setting("student_accountability_rule", "all_enrolled")
      activation = start_campus(officer)

      rules =
        Repo.all(
          from ep in ExpectedPresence,
            where: ep.activation_id == ^activation.id,
            select: ep.rule_applied
        )

      assert Enum.sort(rules) == ["all_enrolled", "all_enrolled", "staff_by_location"]

      {:ok, _} = Activations.close_activation(activation, actor: officer)
      {:ok, _} = Settings.put_setting("student_accountability_rule", "timetable_expected")

      assert_raise ArgumentError, ~r/timetable_expected.*not supported/, fn ->
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)
      end

      # the raise rolled the whole start back
      assert Activations.list_activations(status: "active") == []
    end

    test "zones scope expects staff by usual area or department area only", %{officer: officer} do
      zone_in = zone_fixture()
      zone_out = zone_fixture()
      {:ok, area_in} = Locations.create_area(%{name: "In", zone_id: zone_in.id})
      {:ok, area_out} = Locations.create_area(%{name: "Out", zone_id: zone_out.id})
      dept_in = department_fixture()
      dept_out = department_fixture()
      {:ok, _} = Locations.link_department_to_area(dept_in, area_in)
      {:ok, _} = Locations.link_department_to_area(dept_out, area_out)

      by_primary = person_fixture(%{type: "staff", primary_department_id: dept_in.id})
      by_usual_area = person_fixture(%{type: "staff", usual_area_id: area_in.id})
      by_secondary = person_fixture(%{type: "staff", primary_department_id: dept_out.id})
      {:ok, _} = Salvorion.Roster.register_person_department(by_secondary, dept_in)
      _elsewhere = person_fixture(%{type: "staff", primary_department_id: dept_out.id})
      _nowhere = person_fixture(%{type: "staff"})

      {:ok, activation} =
        Activations.start_activation(
          %{activation_type: "drill", scope: "zones", zone_ids: [zone_in.id]},
          actor: officer
        )

      expected_ids =
        Repo.all(
          from ep in ExpectedPresence,
            where: ep.activation_id == ^activation.id,
            select: ep.person_id
        )

      assert MapSet.new(expected_ids) ==
               MapSet.new([by_primary.id, by_usual_area.id, by_secondary.id])
    end
  end

  # ---------------------------------------------------------------------------
  # Ingest: idempotency, gates, permissions
  # ---------------------------------------------------------------------------

  describe "ingest_event/2 gates" do
    test "same client_uuid twice: one row, :duplicate, nothing written (I3)", %{officer: officer} do
      person = person_fixture()
      activation = start_campus(officer)
      attrs = event_attrs(activation, person, [])

      assert {:ok, event, %PersonStatus{status: "present"}} =
               Accountability.ingest_event(attrs, actor: officer)

      assert {:ok, ^event, :duplicate} = Accountability.ingest_event(attrs, actor: officer)
      assert Accountability.count_events(activation.id) == 1
      assert [_] = Audit.list_audit_logs(action: "accountability.event_ingested")
    end

    test "resolves id_number; unknown card writes nothing", %{officer: officer} do
      person = person_fixture(%{id_number: "CARD-42"})
      activation = start_campus(officer)

      assert {:ok, event, _} =
               Accountability.ingest_event(
                 activation
                 |> event_attrs(person, [])
                 |> Map.delete(:person_id)
                 |> Map.put(:id_number, "CARD-42"),
                 actor: officer
               )

      assert event.person_id == person.id

      assert {:error, :unknown_person} =
               Accountability.ingest_event(
                 activation
                 |> event_attrs(person, [])
                 |> Map.delete(:person_id)
                 |> Map.put(:id_number, "NOPE-000"),
                 actor: officer
               )

      assert Accountability.count_events(activation.id) == 1
    end

    test "scheduled activation is rejected", %{officer: officer} do
      person = person_fixture()

      {:ok, scheduled} =
        Activations.schedule_activation(
          %{activation_type: "drill", started_at: DateTime.utc_now()},
          actor: officer
        )

      assert {:error, :activation_not_started} =
               Accountability.ingest_event(event_attrs(scheduled, person, []), actor: officer)
    end

    test "late events: within 5 minutes of closed_at accepted, later rejected, audited after report",
         %{officer: officer} do
      person = person_fixture()
      activation = start_campus(officer)
      {:ok, closed} = Activations.close_activation(activation, actor: officer)

      assert {:ok, _, %PersonStatus{status: "present"}} =
               Accountability.ingest_event(
                 event_attrs(closed, person,
                   client_timestamp: DateTime.add(closed.closed_at, 120)
                 ),
                 actor: officer
               )

      assert {:error, :activation_closed} =
               Accountability.ingest_event(
                 event_attrs(closed, person,
                   client_timestamp: DateTime.add(closed.closed_at, 600)
                 ),
                 actor: officer
               )

      {:ok, reported} = Activations.mark_activation_reported(closed)

      assert {:ok, event, _} =
               Accountability.ingest_event(
                 event_attrs(reported, person,
                   client_timestamp: DateTime.add(closed.closed_at, 60)
                 ),
                 actor: officer
               )

      assert [log] = Audit.list_audit_logs(action: "accountability.late_event_after_report")
      assert log.entity_id == activation.id
      assert log.after["event_id"] == event.id
    end

    test "review actions have no post-close window; field events keep it", %{officer: officer} do
      person = person_fixture()
      activation = start_campus(officer)
      ingest!(activation, person, officer)
      {:ok, closed} = Activations.close_activation(activation, actor: officer)
      thirty_min_late = DateTime.add(closed.closed_at, 30 * 60)

      assert {:error, :activation_closed} =
               Accountability.ingest_event(
                 event_attrs(closed, person,
                   kind: "roll_call",
                   status: "absent",
                   client_timestamp: thirty_min_late
                 ),
                 actor: officer
               )

      assert {:ok, _, %PersonStatus{status: "excused"}} =
               Accountability.ingest_event(
                 event_attrs(closed, person,
                   kind: "override",
                   status: "excused",
                   note: "confirmed safe by phone",
                   client_timestamp: thirty_min_late
                 ),
                 actor: officer
               )

      # still audited for a regenerate once the activation is reported
      {:ok, reported} = Activations.mark_activation_reported(closed)

      assert {:ok, event, _} =
               Accountability.ingest_event(
                 event_attrs(reported, person,
                   kind: "override",
                   status: "present",
                   note: "seen at the gate",
                   client_timestamp: DateTime.add(closed.closed_at, 60 * 60)
                 ),
                 actor: officer
               )

      assert [log] = Audit.list_audit_logs(action: "accountability.late_event_after_report")
      assert log.after["event_id"] == event.id

      # and a review action is still refused on a scheduled activation
      {:ok, scheduled} =
        Activations.schedule_activation(
          %{activation_type: "drill", started_at: DateTime.utc_now()},
          actor: officer
        )

      assert {:error, :activation_not_started} =
               Accountability.ingest_event(
                 event_attrs(scheduled, person, kind: "override", status: "excused", note: "x"),
                 actor: officer
               )
    end

    test "override needs a note and an osh_officer/admin recorder", %{officer: officer} do
      person = person_fixture()
      activation = start_campus(officer)
      warden = user_fixture(%{role: "warden"})

      assert {:error, changeset} =
               Accountability.ingest_event(
                 event_attrs(activation, person, kind: "override", status: "excused"),
                 actor: officer
               )

      assert %{note: ["can't be blank"]} = errors_on(changeset)

      assert {:error, :override_not_permitted} =
               Accountability.ingest_event(
                 event_attrs(activation, person,
                   kind: "override",
                   status: "excused",
                   note: "phoned"
                 ),
                 actor: warden
               )

      assert {:ok, _, %PersonStatus{status: "excused"}} =
               Accountability.ingest_event(
                 event_attrs(activation, person,
                   kind: "override",
                   status: "excused",
                   note: "phoned"
                 ),
                 actor: officer
               )

      assert Accountability.count_events(activation.id) == 1
    end
  end

  # ---------------------------------------------------------------------------
  # Derivation and contradictions
  # ---------------------------------------------------------------------------

  describe "status derivation" do
    test "second distinct scan keeps present with no contradiction (FR-SIGN-06)", %{
      officer: officer
    } do
      person = person_fixture()
      activation = start_campus(officer)
      {first, _} = ingest!(activation, person, officer)
      {second, status} = ingest!(activation, person, officer)

      assert Accountability.count_events(activation.id) == 2
      assert status.status == "present"
      assert status.source_event_id == second.id
      assert status.contradicting_event_id == nil

      assert Accountability.list_events_for_person(activation.id, person.id) |> Enum.map(& &1.id) ==
               [first.id, second.id]
    end

    test "scan then roll_call/absent, and the reverse, both flag the roll call (FR-ROLL-05)", %{
      officer: officer
    } do
      p1 = person_fixture()
      p2 = person_fixture()
      activation = start_campus(officer)

      {_scan1, _} = ingest!(activation, p1, officer)
      {rc1, s1} = ingest!(activation, p1, officer, kind: "roll_call", status: "absent")

      {rc2, _} = ingest!(activation, p2, officer, kind: "roll_call", status: "absent")
      {_scan2, s2} = ingest!(activation, p2, officer)

      for {s, rc} <- [{s1, rc1}, {s2, rc2}] do
        assert s.status == "present"
        assert s.contradicting_event_id == rc.id
        assert s.contradiction_resolved_at == nil
      end

      assert Accountability.count_open_contradictions(activation.id) == 2
    end

    test "a warden correcting their own roll call is not a contradiction", %{officer: officer} do
      person = person_fixture()
      activation = start_campus(officer)
      ingest!(activation, person, officer, kind: "roll_call", status: "absent")

      {corrected, status} =
        ingest!(activation, person, officer, kind: "roll_call", status: "present")

      assert status.status == "present"
      assert status.source_event_id == corrected.id
      assert status.contradicting_event_id == nil
      assert Accountability.count_open_contradictions(activation.id) == 0
    end

    test "resolve, re-resolve, and re-flag on a new contradicting event", %{officer: officer} do
      person = person_fixture()
      activation = start_campus(officer)
      ingest!(activation, person, officer)
      {rc, _} = ingest!(activation, person, officer, kind: "roll_call", status: "absent")

      assert {:ok, resolved} =
               Accountability.resolve_contradiction(activation.id, person.id, actor: officer)

      assert resolved.status == "present"
      assert resolved.contradicting_event_id == rc.id
      assert %DateTime{} = resolved.contradiction_resolved_at
      assert Accountability.count_open_contradictions(activation.id) == 0

      assert {:error, :no_open_contradiction} =
               Accountability.resolve_contradiction(activation.id, person.id, actor: officer)

      # the confirmation is an event: present, never a status change
      assert [%AccountabilityEvent{kind: "contradiction_resolved", status: "present"} = res_event] =
               Enum.filter(
                 Accountability.list_events_for_person(activation.id, person.id),
                 &(&1.kind == "contradiction_resolved")
               )

      assert resolved.contradiction_resolved_at == res_event.server_timestamp
      assert resolved.source_event_id != res_event.id

      # a further scan re-derives from events and keeps the resolution
      {_, after_scan} = ingest!(activation, person, officer)
      assert after_scan.contradicting_event_id == rc.id
      assert after_scan.contradiction_resolved_at == resolved.contradiction_resolved_at

      {rc2, reflagged} = ingest!(activation, person, officer, kind: "roll_call", status: "absent")
      assert reflagged.contradicting_event_id == rc2.id
      assert reflagged.contradiction_resolved_at == nil
      assert Accountability.count_open_contradictions(activation.id) == 1

      # same audit path as every other event; replaying the client_uuid is a no-op
      logs = Audit.list_audit_logs(action: "accountability.event_ingested")

      assert Enum.any?(
               logs,
               &(&1.after["kind"] == "contradiction_resolved" and &1.actor_user_id == officer.id)
             )

      uuid = Ecto.UUID.generate()

      {:ok, _} =
        Accountability.resolve_contradiction(activation.id, person.id,
          actor: officer,
          client_uuid: uuid
        )

      {:ok, _} =
        Accountability.resolve_contradiction(activation.id, person.id,
          actor: officer,
          client_uuid: uuid
        )

      assert Accountability.count_open_contradictions(activation.id) == 0

      assert 2 ==
               activation.id
               |> Accountability.list_events_for_person(person.id)
               |> Enum.count(&(&1.kind == "contradiction_resolved"))
    end

    test "override wins over everything and resolves the contradiction", %{officer: officer} do
      person = person_fixture()
      activation = start_campus(officer)
      ingest!(activation, person, officer, kind: "roll_call", status: "absent")
      ingest!(activation, person, officer)

      {override, status} =
        ingest!(activation, person, officer, kind: "override", status: "excused", note: "phoned")

      assert status.status == "excused"
      assert status.source_event_id == override.id
      assert status.contradiction_resolved_at == override.server_timestamp
      assert Accountability.count_open_contradictions(activation.id) == 0

      # a later scan does not outrank the override
      {_, later} = ingest!(activation, person, officer)
      assert later.status == "excused"
    end

    test "derive_status/2 returns :none for nobody, unaccounted for expected", %{officer: officer} do
      staff = person_fixture(%{type: "staff"})
      student = person_fixture(%{type: "student"})
      activation = start_campus(officer)

      assert Accountability.derive_status(activation.id, student.id) == :none

      assert %{status: "unaccounted", source_event_id: nil} =
               Accountability.derive_status(activation.id, staff.id)
    end

    test "rebuild_person_status/2 restores a deleted row field-for-field from events (I4)",
         %{
           officer: officer
         } do
      person = person_fixture(%{type: "staff"})
      activation = start_campus(officer)
      ingest!(activation, person, officer)
      {rc, _} = ingest!(activation, person, officer, kind: "roll_call", status: "absent")

      {:ok, original} =
        Accountability.resolve_contradiction(activation.id, person.id, actor: officer)

      # test-only: the one place a PersonStatus is ever deleted
      Repo.delete!(original)

      assert {:ok, rebuilt} =
               Accountability.rebuild_person_status(activation.id, person.id, actor: officer)

      assert rebuilt.status == original.status
      assert rebuilt.source_event_id == original.source_event_id
      assert rebuilt.contradicting_event_id == rc.id
      # the warden's confirmation is an event, so it survives the rebuild
      assert rebuilt.contradiction_resolved_at == original.contradiction_resolved_at
      assert %DateTime{} = rebuilt.contradiction_resolved_at

      assert {:ok, 1} = Accountability.rebuild_activation_statuses(activation.id, actor: officer)
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrency: same technique as the Activations test — two real
  # connections, :auto sandbox mode, explicit cleanup.
  # ---------------------------------------------------------------------------

  @tag :concurrency
  test "two concurrent scans of one person: two events, one status row", %{
    officer: officer_sandboxed
  } do
    _ = officer_sandboxed
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    officer = user_fixture(%{role: "osh_officer"})
    person = person_fixture()
    activation = start_campus(officer)

    try do
      results =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Accountability.ingest_event(event_attrs(activation, person, []), actor: officer)
          end)
        end)
        |> Enum.map(&Task.await(&1, 10_000))

      assert Enum.all?(
               results,
               &match?({:ok, %AccountabilityEvent{}, %PersonStatus{status: "present"}}, &1)
             )

      assert Accountability.count_events(activation.id) == 2

      assert Repo.aggregate(
               from(ps in PersonStatus,
                 where: ps.activation_id == ^activation.id and ps.person_id == ^person.id
               ),
               :count
             ) == 1
    after
      Repo.delete_all(from ps in PersonStatus, where: ps.activation_id == ^activation.id)
      Repo.delete_all(from ep in ExpectedPresence, where: ep.activation_id == ^activation.id)
      Repo.delete_all(from e in AccountabilityEvent, where: e.activation_id == ^activation.id)

      Repo.delete_all(
        from l in Audit.AuditLog, where: l.entity_id in ^[activation.id, person.id, officer.id]
      )

      Repo.delete_all(from l in Audit.AuditLog, where: l.actor_user_id == ^officer.id)
      Repo.delete_all(from l in Audit.AuditLog, where: l.entity_type == "accountability_event")
      Repo.delete_all(from a in Salvorion.Activations.Activation, where: a.id == ^activation.id)
      Repo.delete_all(from p in Salvorion.Roster.Person, where: p.id == ^person.id)
      Repo.delete_all(from u in Salvorion.Accounts.User, where: u.id == ^officer.id)
    end
  end
end
