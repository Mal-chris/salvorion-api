defmodule Salvorion.AccountabilityReadsTest do
  # async: false — some tests toggle the sandbox to :auto mode for the
  # PubSub-across-commit check.
  use Salvorion.DataCase, async: false

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.Accountability
  alias Salvorion.Accountability.Scope
  alias Salvorion.{Accounts, Activations, Locations, Organisation, Roster}

  # ---------------------------------------------------------------------------
  # Fixture: a zone with two areas, each linked to a department, plus a
  # zone "outside" with its own department. Mirrors the verification setup
  # at a small scale (CIS/Stores-style split within one zone).
  # ---------------------------------------------------------------------------

  defp topology do
    zone_a = zone_fixture()
    zone_b = zone_fixture()

    {:ok, area_a1} = Locations.create_area(%{name: "Area A1", zone_id: zone_a.id})
    {:ok, area_a2} = Locations.create_area(%{name: "Area A2", zone_id: zone_a.id})
    {:ok, area_b1} = Locations.create_area(%{name: "Area B1", zone_id: zone_b.id})

    dept_a1 = department_fixture()
    dept_a2 = department_fixture()
    dept_b1 = department_fixture()

    {:ok, _} = Locations.link_department_to_area(dept_a1, area_a1)
    {:ok, _} = Locations.link_department_to_area(dept_a2, area_a2)
    {:ok, _} = Locations.link_department_to_area(dept_b1, area_b1)

    %{
      zone_a: zone_a,
      zone_b: zone_b,
      area_a1: area_a1,
      area_a2: area_a2,
      area_b1: area_b1,
      dept_a1: dept_a1,
      dept_a2: dept_a2,
      dept_b1: dept_b1
    }
  end

  defp start_campus(officer) do
    {:ok, activation} = Activations.start_activation(%{activation_type: "drill"}, actor: officer)
    activation
  end

  defp scan!(activation, person, officer, overrides \\ []) do
    attrs =
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

    {:ok, event, status} = Accountability.ingest_event(attrs, actor: officer)
    {event, status}
  end

  setup do
    %{officer: user_fixture(%{role: "osh_officer"})}
  end

  # ---------------------------------------------------------------------------
  # Scope
  # ---------------------------------------------------------------------------

  describe "Scope.person_areas/1 and warden_scope/2" do
    test "person_areas unions usual_area with every department's areas, deduplicated", %{
      officer: _officer
    } do
      %{area_a1: area_a1, area_a2: area_a2, dept_a1: dept_a1, dept_a2: dept_a2} = topology()

      person =
        person_fixture(%{
          type: "staff",
          primary_department_id: dept_a1.id,
          usual_area_id: area_a2.id
        })

      {:ok, _} = Roster.register_person_department(person, dept_a2)

      assert Scope.person_areas(person.id) |> Enum.sort() == Enum.sort([area_a1.id, area_a2.id])
    end

    test "warden_scope expands a zone assignment to its areas, an area assignment to its zone", %{
      officer: _officer
    } do
      %{zone_a: zone_a, area_a1: area_a1, area_a2: area_a2, zone_b: zone_b, area_b1: area_b1} =
        topology()

      zone_warden = user_fixture(%{role: "warden"})
      area_warden = user_fixture(%{role: "warden"})

      {:ok, _} = Accounts.assign_warden(zone_warden.id, {:zone, zone_a.id}, {~D[2020-01-01], nil})

      {:ok, _} =
        Accounts.assign_warden(area_warden.id, {:area, area_b1.id}, {~D[2020-01-01], nil})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: user_fixture())

      zone_scope = Scope.warden_scope(zone_warden, activation)
      assert zone_scope.zone_ids == [zone_a.id]
      assert Enum.sort(zone_scope.area_ids) == Enum.sort([area_a1.id, area_a2.id])

      area_scope = Scope.warden_scope(area_warden, activation)
      assert area_scope.zone_ids == [zone_b.id]
      assert area_scope.area_ids == [area_b1.id]
    end
  end

  # ---------------------------------------------------------------------------
  # list_roll_call/2, list_roll_call_for_zone/2, count_unaccounted_for_warden/2
  # ---------------------------------------------------------------------------

  describe "list_roll_call/2" do
    test "returns :no_assignment, :not_a_warden, groups and sorts correctly", %{officer: officer} do
      %{zone_a: zone_a, dept_a1: dept_a1, dept_a2: dept_a2} = topology()

      s1 =
        person_fixture(%{
          type: "staff",
          primary_department_id: dept_a1.id,
          first_name: "Bea",
          last_name: "Ashcombe"
        })

      s2 =
        person_fixture(%{
          type: "staff",
          primary_department_id: dept_a2.id,
          first_name: "Cal",
          last_name: "Brightwell"
        })

      warden = user_fixture(%{role: "warden"})
      {:ok, _} = Accounts.assign_warden(warden.id, {:zone, zone_a.id}, {~D[2020-01-01], nil})

      activation = start_campus(officer)

      no_assignment_warden = user_fixture(%{role: "warden"})

      assert {:error, :no_assignment} =
               Accountability.list_roll_call(activation, no_assignment_warden)

      assert {:error, :not_a_warden} = Accountability.list_roll_call(activation, officer)

      {:ok, roll_call} = Accountability.list_roll_call(activation, warden)

      assert Enum.map(roll_call.unaccounted, & &1.person_id) |> Enum.sort() ==
               Enum.sort([s1.id, s2.id])

      assert roll_call.counts.unaccounted == 2
      assert roll_call.flagged == []
      assert roll_call.accounted == []

      # sorted by last_name, first_name
      assert Enum.map(roll_call.unaccounted, & &1.last_name) == ["Ashcombe", "Brightwell"]

      scan!(activation, s1, officer)

      {:ok, roll_call} = Accountability.list_roll_call(activation, warden)
      assert [row] = roll_call.accounted
      assert row.person_id == s1.id
      assert row.status == "present"
      assert row.source_kind == "scanned"
      assert row.contradiction_open? == false
      assert %DateTime{} = row.last_event_at
      assert Enum.map(roll_call.unaccounted, & &1.person_id) == [s2.id]
    end

    test "a flagged contradiction appears in flagged only, and count_unaccounted_for_warden ignores it",
         %{officer: officer} do
      %{zone_a: zone_a, dept_a1: dept_a1} = topology()
      person = person_fixture(%{type: "staff", primary_department_id: dept_a1.id})
      warden = user_fixture(%{role: "warden"})
      {:ok, _} = Accounts.assign_warden(warden.id, {:zone, zone_a.id}, {~D[2020-01-01], nil})

      activation = start_campus(officer)
      before_unaccounted = Accountability.count_unaccounted_for_warden(activation, warden)
      assert before_unaccounted == 1

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
          actor: warden
        )

      {:ok, roll_call} = Accountability.list_roll_call(activation, warden)
      assert Enum.map(roll_call.flagged, & &1.person_id) == [person.id]
      assert roll_call.accounted == []
      assert roll_call.counts.flagged == 1

      # flagged is not unaccounted: unchanged from before, not increased
      assert Accountability.count_unaccounted_for_warden(activation, warden) ==
               before_unaccounted - 1

      {:ok, _} = Accountability.resolve_contradiction(activation.id, person.id, actor: warden)
      {:ok, roll_call} = Accountability.list_roll_call(activation, warden)
      assert roll_call.flagged == []
      assert Enum.map(roll_call.accounted, & &1.person_id) == [person.id]
    end

    test "an expired or future assignment does not apply, only the activation-start-effective one does",
         %{officer: officer} do
      %{zone_a: zone_a, dept_a1: dept_a1} = topology()
      person_fixture(%{type: "staff", primary_department_id: dept_a1.id})
      warden = user_fixture(%{role: "warden"})

      activation = start_campus(officer)

      {:ok, _} =
        Accounts.assign_warden(warden.id, {:zone, zone_a.id}, {~D[2020-01-01], ~D[2020-12-31]})

      assert {:error, :no_assignment} = Accountability.list_roll_call(activation, warden)

      future = Date.add(DateTime.to_date(activation.started_at), 30)
      {:ok, _} = Accounts.assign_warden(warden.id, {:zone, zone_a.id}, {future, nil})
      assert {:error, :no_assignment} = Accountability.list_roll_call(activation, warden)
    end
  end

  describe "list_roll_call_for_zone/2" do
    test "matches the warden's own list for the same zone, no role check", %{officer: officer} do
      %{zone_a: zone_a, dept_a1: dept_a1} = topology()
      person_fixture(%{type: "staff", primary_department_id: dept_a1.id})
      warden = user_fixture(%{role: "warden"})
      {:ok, _} = Accounts.assign_warden(warden.id, {:zone, zone_a.id}, {~D[2020-01-01], nil})

      activation = start_campus(officer)

      {:ok, warden_view} = Accountability.list_roll_call(activation, warden)
      {:ok, zone_view} = Accountability.list_roll_call_for_zone(activation, zone_a.id)

      assert warden_view == zone_view
    end
  end

  # ---------------------------------------------------------------------------
  # Dashboard aggregates
  # ---------------------------------------------------------------------------

  describe "participation_by_department/1 and participation_by_faculty/1" do
    test "rates, the (no department)/(no faculty) buckets, and nil rate at zero expected", %{
      officer: officer
    } do
      {:ok, faculty} = Organisation.create_faculty(%{name: "Faculty of Things", code: "FOT"})
      dept = department_fixture(%{faculty_id: faculty.id})
      staff = person_fixture(%{type: "staff", primary_department_id: dept.id})
      staff_no_dept = person_fixture(%{type: "staff"})
      visitor = person_fixture(%{type: "visitor", source: "visitor_registration"})

      activation = start_campus(officer)
      scan!(activation, staff, officer)
      # a visitor: present but not expected (present_unexpected), no department
      scan!(activation, visitor, officer)

      by_dept = Accountability.participation_by_department(activation.id)
      dept_row = Enum.find(by_dept, &(&1.department_id == dept.id))
      assert dept_row.expected == 1
      assert dept_row.present == 1
      assert dept_row.participation_rate == 1.0
      assert dept_row.accounted_rate == 1.0
      assert dept_row.present_unexpected == 0

      no_dept_row = Enum.find(by_dept, &is_nil(&1.department_id))
      assert no_dept_row.expected == 1
      assert no_dept_row.present == 1
      assert no_dept_row.present_unexpected == 1
      # staff_no_dept is expected (unaccounted, expected=1) and visitor is
      # present_unexpected(1) but not expected — both land in this bucket
      assert no_dept_row.unaccounted == 1

      by_faculty = Accountability.participation_by_faculty(activation.id)
      fac_row = Enum.find(by_faculty, &(&1.faculty_id == faculty.id))
      assert fac_row.expected == 1
      assert fac_row.participation_rate == 1.0

      no_fac_row = Enum.find(by_faculty, &is_nil(&1.faculty_id))
      assert match?(%{}, no_fac_row)
      assert no_fac_row.expected == 1

      assert staff_no_dept.type == "staff"
    end
  end

  describe "counts_by_zone/1" do
    test "a person whose areas span two zones is counted in both; arrivals reflect where people signed in",
         %{officer: officer} do
      %{zone_a: zone_a, zone_b: zone_b, area_a1: area_a1, dept_a1: dept_a1, dept_b1: dept_b1} =
        topology()

      spanning = person_fixture(%{type: "staff", primary_department_id: dept_a1.id})
      {:ok, _} = Roster.register_person_department(spanning, dept_b1)
      only_a = person_fixture(%{type: "staff", primary_department_id: dept_a1.id})

      activation = start_campus(officer)

      zone_a_with_ap =
        Salvorion.Locations.Zone |> Repo.get!(zone_a.id) |> Repo.preload(:assembly_point)

      scan!(activation, only_a, officer,
        assembly_point_id: zone_a_with_ap.assembly_point.id,
        area_id: area_a1.id
      )

      counts = Accountability.counts_by_zone(activation.id)
      row_a = Enum.find(counts, &(&1.zone_id == zone_a.id))
      row_b = Enum.find(counts, &(&1.zone_id == zone_b.id))

      # spanning counted in both zones' expected
      assert row_a.expected == 2
      assert row_b.expected == 1
      assert row_a.arrivals == 1
      assert row_b.arrivals == 0
    end
  end

  describe "unaccounted_list/2" do
    test "filters by department_id, faculty_id, zone_id and type", %{officer: officer} do
      %{zone_a: zone_a, dept_a1: dept_a1, dept_b1: dept_b1} = topology()
      staff_a = person_fixture(%{type: "staff", primary_department_id: dept_a1.id})
      staff_b = person_fixture(%{type: "staff", primary_department_id: dept_b1.id})

      activation = start_campus(officer)

      by_dept = Accountability.unaccounted_list(activation.id, department_id: dept_a1.id)
      assert Enum.map(by_dept, & &1.person_id) == [staff_a.id]

      by_zone = Accountability.unaccounted_list(activation.id, zone_id: zone_a.id)
      assert Enum.map(by_zone, & &1.person_id) == [staff_a.id]

      by_type = Accountability.unaccounted_list(activation.id, type: "staff")
      assert staff_a.id in Enum.map(by_type, & &1.person_id)
      assert staff_b.id in Enum.map(by_type, & &1.person_id)

      assert Accountability.unaccounted_list(activation.id, type: "visitor") == []
    end
  end

  describe "activation_summary/1" do
    test "every field, and expected + present_unexpected accounts for every status row here", %{
      officer: officer
    } do
      dept = department_fixture()
      staff = person_fixture(%{type: "staff", primary_department_id: dept.id})
      visitor = person_fixture(%{type: "visitor", source: "visitor_registration"})

      activation = start_campus(officer)
      scan!(activation, staff, officer)
      scan!(activation, visitor, officer)

      summary = Accountability.activation_summary(activation.id)
      assert summary.expected == 1
      assert summary.present == 2
      assert summary.present_unexpected == 1
      assert summary.arrivals == 2
      assert summary.events == 2
      assert summary.open_contradictions == 0

      total_status_rows =
        Repo.aggregate(
          from(ps in Accountability.PersonStatus, where: ps.activation_id == ^activation.id),
          :count
        )

      assert summary.expected + summary.present_unexpected == total_status_rows
    end
  end

  # ---------------------------------------------------------------------------
  # Broadcast (Task 5)
  # ---------------------------------------------------------------------------

  describe "PubSub broadcasts" do
    test "ingest_event/2 broadcasts :person_status_updated with zone_ids after commit", %{
      officer: officer
    } do
      %{zone_a: zone_a, dept_a1: dept_a1} = topology()
      person = person_fixture(%{type: "staff", primary_department_id: dept_a1.id})
      activation = start_campus(officer)

      :ok = Accountability.subscribe(activation.id)
      scan!(activation, person, officer)

      assert_receive {:person_status_updated,
                      %{
                        activation_id: activation_id,
                        person_id: person_id,
                        status: "present",
                        source_kind: "scanned",
                        contradiction_open?: false,
                        zone_ids: zone_ids
                      }}

      assert activation_id == activation.id
      assert person_id == person.id
      assert zone_a.id in zone_ids
    end

    test "activation lifecycle broadcasts :activation_changed", %{officer: officer} do
      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      :ok = Accountability.subscribe(activation.id)

      {:ok, closed} = Activations.close_activation(activation, actor: officer)
      assert_receive {:activation_changed, %{activation_id: id, status: "closed"}}
      assert id == activation.id

      {:ok, _} = Activations.mark_activation_reported(closed)
      assert_receive {:activation_changed, %{status: "reported"}}
    end

    # A plain nested Repo.transaction doesn't actually test the after-commit
    # rule: Ecto runs a nested transaction as part of the same underlying
    # database transaction (no savepoint for an ordinary nested call), and
    # the broadcast is a plain message send with no relationship to Postgres
    # commit/rollback timing — so wrapping ingest_event in an outer
    # transaction and rolling that back would still fire the broadcast
    # immediately, proving nothing. The real question is whether ingest_event
    # ever broadcasts for a write that *its own* transaction rolled back.
    # Two concurrent ingests racing on the same client_uuid create exactly
    # that: the loser's insert hits a genuine unique_constraint violation and
    # its own Ecto.Multi transaction really does ROLLBACK at the database
    # (see insert_and_derive's {:error, :event, ...} branch, which is never
    # reached from inside the {:ok, ...} branch that broadcasts) — so only
    # the winner's commit produces a message, never the loser's.
    @tag :concurrency
    test "a transaction that rolls back at the database never broadcasts: only the race's winner does",
         %{officer: _officer} do
      Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)
      on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

      officer = user_fixture(%{role: "osh_officer"})
      person = person_fixture()
      activation = start_campus(officer)
      :ok = Accountability.subscribe(activation.id)
      client_uuid = Ecto.UUID.generate()

      attrs = %{
        client_uuid: client_uuid,
        activation_id: activation.id,
        person_id: person.id,
        kind: "scanned",
        status: "present",
        client_timestamp: DateTime.utc_now()
      }

      try do
        results =
          [1, 2]
          |> Enum.map(fn _ ->
            Task.async(fn -> Accountability.ingest_event(attrs, actor: officer) end)
          end)
          |> Enum.map(&Task.await(&1, 10_000))

        assert Enum.count(results, &match?({:ok, _, %Accountability.PersonStatus{}}, &1)) == 1
        assert Enum.count(results, &match?({:ok, _, :duplicate}, &1)) == 1
        assert Accountability.count_events(activation.id) == 1

        # exactly one broadcast, from the winner's real commit — not two
        assert_receive {:person_status_updated, %{person_id: person_id}}
        assert person_id == person.id
        refute_receive {:person_status_updated, _}, 200
      after
        Repo.delete_all(
          from ps in Accountability.PersonStatus, where: ps.activation_id == ^activation.id
        )

        Repo.delete_all(
          from ep in Accountability.ExpectedPresence, where: ep.activation_id == ^activation.id
        )

        Repo.delete_all(
          from e in Accountability.AccountabilityEvent, where: e.activation_id == ^activation.id
        )

        Repo.delete_all(from l in Salvorion.Audit.AuditLog, where: l.entity_id == ^activation.id)

        Repo.delete_all(
          from l in Salvorion.Audit.AuditLog, where: l.entity_type == "accountability_event"
        )

        Repo.delete_all(from a in Activations.Activation, where: a.id == ^activation.id)
        Repo.delete_all(from p in Salvorion.Roster.Person, where: p.id == ^person.id)
        Repo.delete_all(from u in Salvorion.Accounts.User, where: u.id == ^officer.id)
      end
    end
  end
end
