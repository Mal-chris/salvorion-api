defmodule Salvorion.LocationsTest do
  use Salvorion.DataCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.{Audit, Locations, Organisation}

  defp hierarchy_fixture do
    {:ok, ap} = Locations.create_assembly_point(%{name: "Main Parking Lot"})
    {:ok, zone} = Locations.create_zone(%{number: 904, assembly_point_id: ap.id})
    {:ok, area} = Locations.create_area(%{name: "NCU Press", zone_id: zone.id})
    {:ok, dept} = Organisation.create_department(%{name: "NCU Press", code: "NCU_PRESS"})
    %{ap: ap, zone: zone, area: area, dept: dept}
  end

  describe "assembly points" do
    test "create_assembly_point/2 creates, audits, and is found by name" do
      admin = user_fixture()

      assert {:ok, ap} =
               Locations.create_assembly_point(
                 %{name: "Farm Open Field", latitude: "18.04", longitude: "-77.5"},
                 actor: admin
               )

      assert Decimal.equal?(ap.latitude, Decimal.new("18.04"))
      assert Locations.get_assembly_point_by_name("Farm Open Field").id == ap.id
      assert Locations.get_assembly_point_by_name("nope") == nil
      assert [%{id: id}] = Locations.list_assembly_points()
      assert id == ap.id

      assert [log] = Audit.list_audit_logs(entity_type: "assembly_point", entity_id: ap.id)
      assert log.action == "assembly_point.created"
      assert log.actor_user_id == admin.id
      assert log.after["name"] == "Farm Open Field"
    end

    test "create_assembly_point/2 requires a name" do
      assert {:error, changeset} = Locations.create_assembly_point(%{})
      assert %{name: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "zones" do
    test "create_zone/2 validates the assembly point exists before inserting" do
      assert {:error, changeset} =
               Locations.create_zone(%{number: 905, assembly_point_id: Ecto.UUID.generate()})

      assert %{assembly_point_id: ["does not exist"]} = errors_on(changeset)

      assert {:error, changeset} = Locations.create_zone(%{number: 905})
      assert %{assembly_point_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "create_zone/2 enforces unique numbers and list_zones/0 orders by number" do
      {:ok, ap} = Locations.create_assembly_point(%{name: "AP"})
      {:ok, z2} = Locations.create_zone(%{number: 912, assembly_point_id: ap.id})
      {:ok, z1} = Locations.create_zone(%{number: 911, assembly_point_id: ap.id})

      assert {:error, changeset} = Locations.create_zone(%{number: 911, assembly_point_id: ap.id})
      assert %{number: ["has already been taken"]} = errors_on(changeset)

      assert [first, second] = Locations.list_zones()
      assert [first.id, second.id] == [z1.id, z2.id]
      assert first.assembly_point.id == ap.id
      assert Locations.get_zone_by_number(912).id == z2.id
      assert Locations.get_zone_by_number(999) == nil
      assert [%{action: "zone.created"}] = Audit.list_audit_logs(entity_id: z1.id)
    end
  end

  describe "areas" do
    test "create_area/2 validates the zone exists and list_areas_for_zone/1 orders by name" do
      %{zone: zone} = hierarchy_fixture()

      assert {:error, changeset} =
               Locations.create_area(%{name: "X", zone_id: Ecto.UUID.generate()})

      assert %{zone_id: ["does not exist"]} = errors_on(changeset)

      {:ok, _} = Locations.create_area(%{name: "Biology Department", zone_id: zone.id})

      assert ["Biology Department", "NCU Press"] =
               Locations.list_areas_for_zone(zone) |> Enum.map(& &1.name)

      assert Locations.get_area_by_name(zone.id, "NCU Press")
      assert Locations.get_area_by_name(zone.id, "missing") == nil
    end
  end

  describe "department <-> area links" do
    test "link and unlink go through department_areas and are both audited" do
      admin = user_fixture()
      %{area: area, dept: dept} = hierarchy_fixture()

      assert {:ok, link} = Locations.link_department_to_area(dept, area, actor: admin)
      assert link.department_id == dept.id and link.area_id == area.id
      assert Locations.get_link(dept.id, area.id).id == link.id

      # linking twice is a changeset error, not a crash
      assert {:error, changeset} = Locations.link_department_to_area(dept.id, area.id)
      assert %{department_id: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, deleted} = Locations.unlink_department_from_area(dept, area, actor: admin)
      assert deleted.id == link.id
      assert Locations.get_link(dept.id, area.id) == nil
      assert {:error, :not_found} = Locations.unlink_department_from_area(dept, area)

      logs = Audit.list_audit_logs(entity_type: "department_area", entity_id: link.id)

      assert Enum.map(logs, & &1.action) |> Enum.sort() == [
               "department_area.linked",
               "department_area.unlinked"
             ]

      unlinked = Enum.find(logs, &(&1.action == "department_area.unlinked"))
      assert unlinked.before["area_id"] == area.id
      assert unlinked.after == nil
      assert Enum.all?(logs, &(&1.actor_user_id == admin.id))
    end

    test "link rejects unknown department or area before hitting the database" do
      %{area: area, dept: dept} = hierarchy_fixture()

      assert {:error, changeset} = Locations.link_department_to_area(Ecto.UUID.generate(), area)
      assert %{department_id: ["does not exist"]} = errors_on(changeset)

      assert {:error, changeset} = Locations.link_department_to_area(dept, Ecto.UUID.generate())
      assert %{area_id: ["does not exist"]} = errors_on(changeset)
    end
  end

  describe "get_assembly_point_hierarchy/0" do
    test "nests zones, areas and departments in guide order" do
      {:ok, ap_b} = Locations.create_assembly_point(%{name: "B"})
      {:ok, ap_a} = Locations.create_assembly_point(%{name: "A"})
      {:ok, _empty} = Locations.create_assembly_point(%{name: "Empty"})
      {:ok, z2} = Locations.create_zone(%{number: 922, assembly_point_id: ap_a.id})
      {:ok, z1} = Locations.create_zone(%{number: 921, assembly_point_id: ap_b.id})
      {:ok, steel} = Locations.create_area(%{name: "Steel Building", zone_id: z1.id})
      {:ok, _} = Locations.create_area(%{name: "Annex", zone_id: z1.id})
      {:ok, _} = Locations.create_area(%{name: "Lab", zone_id: z2.id})
      {:ok, d2} = Organisation.create_department(%{name: "Research", code: "RESEARCH"})
      {:ok, d1} = Organisation.create_department(%{name: "Allied Health", code: "ALLIED"})
      {:ok, _} = Locations.link_department_to_area(d2, steel)
      {:ok, _} = Locations.link_department_to_area(d1, steel)

      assert [first, second, third] = Locations.get_assembly_point_hierarchy()
      # ordered by lowest zone number, empty assembly point last
      assert first.name == "B" and second.name == "A" and third.name == "Empty"
      assert [%{number: 921, areas: [annex, steel_loaded]}] = first.zones
      assert annex.name == "Annex" and annex.departments == []
      assert steel_loaded.name == "Steel Building"
      assert Enum.map(steel_loaded.departments, & &1.name) == ["Allied Health", "Research"]
      assert third.zones == []
    end
  end
end
