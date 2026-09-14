defmodule Salvorion.RosterVisitorsTest do
  use Salvorion.DataCase, async: false

  import Salvorion.AccountsFixtures

  alias Salvorion.Accountability
  alias Salvorion.Accountability.AccountabilityEvent
  alias Salvorion.{Accounts, Activations, Audit, Roster, Settings}

  @pass_code_regex ~r/^VIS-[0-9A-HJKMNP-TV-Z]{8}$/

  defp start_campus(officer) do
    {:ok, activation} = Activations.start_activation(%{activation_type: "drill"}, actor: officer)
    activation
  end

  describe "register_visitor/2" do
    test "creates a visitor with a VIS- pass code, audits it, returns {:ok, person, nil} with no activation" do
      officer = user_fixture(%{role: "osh_officer"})

      assert {:ok, person, nil} =
               Roster.register_visitor(
                 %{first_name: "Odalys", last_name: "Whitcombe", visitor_host: "Prof. Ashgrove"},
                 actor: officer
               )

      assert person.type == "visitor"
      assert person.source == "visitor_registration"
      assert person.id_number =~ @pass_code_regex
      assert person.visitor_expires_at == Date.utc_today()

      assert [log] = Audit.list_audit_logs(entity_type: "person", entity_id: person.id)
      assert log.action == "visitor.registered"
      assert log.actor_user_id == officer.id
      assert log.after["person_id"] == person.id
      assert log.after["pass_code"] == person.id_number
      assert log.after["visitor_expires_at"] == to_string(person.visitor_expires_at)

      # no personal data in this audit row — see the "no personal data
      # in the visitor.registered audit row" test below for the full check
      refute Map.has_key?(log.after, "first_name")
      refute Map.has_key?(log.after, "visitor_host")
    end

    test "the visitor.registered audit row's after payload carries no personal data" do
      assert {:ok, person, nil} =
               Roster.register_visitor(%{
                 first_name: "Private",
                 last_name: "Griffiths",
                 visitor_host: "Dr. Okonkwo",
                 phone: "876-555-0142",
                 email: "private.griffiths@example.com"
               })

      assert [log] = Audit.list_audit_logs(entity_type: "person", entity_id: person.id)
      assert log.action == "visitor.registered"

      personal_fields = ~w(first_name last_name name visitor_host host phone email)

      for field <- personal_fields do
        refute Map.has_key?(log.after, field),
               "audit after-payload for visitor.registered must not carry #{field}, got: #{inspect(log.after)}"
      end

      # every value actually present must not itself be one of the
      # personal values supplied above (guards against the field being
      # renamed rather than removed)
      values = Map.values(log.after)
      refute person.first_name in values
      refute person.last_name in values
      refute "Dr. Okonkwo" in values
      refute "876-555-0142" in values
      refute "private.griffiths@example.com" in values
    end

    test "purging a visitor does not need to touch their registration audit row, because it was never written there" do
      assert {:ok, person, nil} =
               Roster.register_visitor(%{
                 first_name: "ToBePurged",
                 last_name: "Visitor",
                 visitor_host: "Someone",
                 phone: "555-0199",
                 email: "purge-me@example.com",
                 visitor_expires_at: Date.add(Date.utc_today(), -91)
                 # default 90-day retention makes this eligible immediately
               })

      assert [log_before] = Audit.list_audit_logs(entity_type: "person", entity_id: person.id)
      refute Map.has_key?(log_before.after, "first_name")
      refute Map.has_key?(log_before.after, "visitor_host")

      assert {:ok, 1} = Roster.purge_expired_visitors()

      assert [log_after] = Audit.list_audit_logs(entity_type: "person", entity_id: person.id)

      # unchanged: the registration audit row is not touched by the purge
      assert log_after.after == log_before.after
      refute Map.has_key?(log_after.after, "first_name")
      refute Map.has_key?(log_after.after, "visitor_host")
      refute Map.has_key?(log_after.after, "phone")
      refute Map.has_key?(log_after.after, "email")
    end

    test "requires visitor_host" do
      assert {:error, changeset} =
               Roster.register_visitor(%{first_name: "No", last_name: "Host"})

      assert %{visitor_host: ["can't be blank"]} = errors_on(changeset)
    end

    test "accepts an explicit visitor_expires_at" do
      expires = Date.add(Date.utc_today(), 3)

      assert {:ok, person, nil} =
               Roster.register_visitor(%{
                 first_name: "Future",
                 last_name: "Guest",
                 visitor_host: "Someone",
                 visitor_expires_at: expires
               })

      assert person.visitor_expires_at == expires
    end

    test "with an activation_id, ingests a visitor_registered event after the person is created",
         %{} do
      officer = user_fixture(%{role: "osh_officer"})
      warden = user_fixture(%{role: "warden"})
      zone = zone_fixture()
      {:ok, area} = Salvorion.Locations.create_area(%{name: "Gate", zone_id: zone.id})
      zone_with_ap = Repo.preload(zone, :assembly_point)
      {:ok, _} = Accounts.assign_warden(warden.id, {:zone, zone.id}, {~D[2020-01-01], nil})

      activation = start_campus(officer)

      assert {:ok, person, %AccountabilityEvent{} = event} =
               Roster.register_visitor(
                 %{first_name: "Vex", last_name: "Harrow", visitor_host: "Dean's Office"},
                 activation_id: activation.id,
                 assembly_point_id: zone_with_ap.assembly_point.id,
                 area_id: area.id,
                 recorded_by_id: warden.id
               )

      assert event.kind == "visitor_registered"
      assert event.status == "present"
      assert event.person_id == person.id

      {:ok, roll_call} = Accountability.list_roll_call(activation, warden)
      row = Enum.find(roll_call.accounted, &(&1.person_id == person.id))
      assert row.type == "visitor"
      assert row.status == "present"

      summary = Accountability.activation_summary(activation.id)
      assert summary.present_unexpected == 1
      assert summary.arrivals == 1
    end

    test "with an activation_id that has closed beyond the late-event window, the person still exists" do
      officer = user_fixture(%{role: "osh_officer"})
      activation = start_campus(officer)
      {:ok, closed} = Activations.close_activation(activation, actor: officer)

      assert {:ok, person, {:error, :activation_closed}} =
               Roster.register_visitor(
                 %{first_name: "Late", last_name: "Arrival", visitor_host: "Someone"},
                 activation_id: activation.id,
                 recorded_by_id: officer.id,
                 client_timestamp: DateTime.add(closed.closed_at, 10 * 60)
               )

      assert person.type == "visitor"
      assert Roster.get_person_by_id_number(person.id_number).id == person.id
      assert Accountability.count_events(activation.id) == 0
    end

    test "the pass code resolves a scan exactly like a staff card; a second scan adds no contradiction" do
      officer = user_fixture(%{role: "osh_officer"})
      activation = start_campus(officer)

      {:ok, person, event1} =
        Roster.register_visitor(
          %{first_name: "Scan", last_name: "Me", visitor_host: "Reception"},
          activation_id: activation.id,
          recorded_by_id: officer.id
        )

      assert %AccountabilityEvent{} = event1

      resolved = Roster.get_person_by_id_number(person.id_number)
      assert resolved.id == person.id

      {:ok, event2, status} =
        Accountability.ingest_event(
          %{
            client_uuid: Ecto.UUID.generate(),
            activation_id: activation.id,
            id_number: person.id_number,
            kind: "scanned",
            status: "present",
            client_timestamp: DateTime.utc_now()
          },
          actor: officer
        )

      assert event2.person_id == person.id
      assert status.status == "present"
      assert status.contradicting_event_id == nil
      assert Accountability.count_events(activation.id) == 2
    end
  end

  describe "visitor_pass/1" do
    test "returns the pass-screen shape" do
      {:ok, person, nil} =
        Roster.register_visitor(%{first_name: "Pass", last_name: "Holder", visitor_host: "IT"})

      assert Roster.visitor_pass(person) == %{
               pass_code: person.id_number,
               first_name: "Pass",
               last_name: "Holder",
               visitor_host: "IT",
               visitor_expires_at: Date.utc_today()
             }
    end
  end

  describe "list_visitors/1" do
    test "active_on filters by visitor_expires_at, defaulting to today" do
      {:ok, active, nil} =
        Roster.register_visitor(%{first_name: "Still", last_name: "Here", visitor_host: "X"})

      {:ok, expired, nil} =
        Roster.register_visitor(%{
          first_name: "Gone",
          last_name: "Already",
          visitor_host: "X",
          visitor_expires_at: Date.add(Date.utc_today(), -1)
        })

      ids = Roster.list_visitors() |> Enum.map(& &1.id)
      assert active.id in ids
      refute expired.id in ids

      past_ids =
        Roster.list_visitors(active_on: Date.add(Date.utc_today(), -1)) |> Enum.map(& &1.id)

      assert expired.id in past_ids
    end
  end

  describe "purge_expired_visitors/1" do
    defp visitor_expired(days_ago) do
      {:ok, person, nil} =
        Roster.register_visitor(%{
          first_name: "Old",
          last_name: "Visitor",
          visitor_host: "Someone",
          phone: "555-0100",
          email: "old@example.com",
          visitor_expires_at: Date.add(Date.utc_today(), -days_ago)
        })

      person
    end

    test "anonymises only visitors past retention, keeps id_number and the row, one audit row, idempotent" do
      officer = user_fixture(%{role: "osh_officer"})
      activation = start_campus(officer)

      old_100 = visitor_expired(100)

      {:ok, _person, event} =
        Roster.register_visitor(
          %{
            first_name: "Old91",
            last_name: "Visitor",
            visitor_host: "Someone",
            visitor_expires_at: Date.add(Date.utc_today(), -91)
          },
          activation_id: activation.id,
          recorded_by_id: officer.id
        )

      old_91_id = event.person_id
      untouched = visitor_expired(89)

      assert {:ok, 2} = Roster.purge_expired_visitors()

      for id <- [old_100.id, old_91_id] do
        p = Roster.get_person!(id)
        assert p.first_name == "Visitor"
        assert p.last_name == "(purged)"
        assert p.email == nil
        assert p.phone == nil
        assert p.visitor_host == nil
        assert p.id_number != nil
      end

      still_there = Roster.get_person!(untouched.id)
      assert still_there.first_name == "Old"
      assert still_there.visitor_host == "Someone"

      assert [log] = Audit.list_audit_logs(action: "visitor.purged")
      assert log.actor_user_id == nil
      assert log.after["count"] == 2
      assert log.after["retention_days"] == 90

      # the item-4-style event/status from before the purge still resolve,
      # and the (purged, but retained) id_number still finds the person
      assert Accountability.get_person_status(activation.id, old_91_id).status == "present"
      assert [_] = Accountability.list_events_for_person(activation.id, old_91_id)
      purged_person = Roster.get_person!(old_91_id)
      assert Roster.get_person_by_id_number(purged_person.id_number).id == old_91_id

      # idempotent: running again finds nothing new
      assert {:ok, 0} = Roster.purge_expired_visitors()
      assert [_second, _first] = Audit.list_audit_logs(action: "visitor.purged")
      assert Enum.find(Audit.list_audit_logs(action: "visitor.purged"), &(&1.after["count"] == 0))
    end

    test "honours the visitor_retention_days setting" do
      {:ok, _} = Settings.put_setting("visitor_retention_days", 30)
      visitor = visitor_expired(31)

      assert {:ok, 1} = Roster.purge_expired_visitors()
      assert Roster.get_person!(visitor.id).first_name == "Visitor"

      {:ok, _} = Settings.put_setting("visitor_retention_days", 90)
    end
  end
end
