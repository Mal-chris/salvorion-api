defmodule Salvorion.Seeds.LocationsTest do
  # Not async: Code.require_file defines the seed module once per VM and the
  # test asserts on absolute row counts.
  use Salvorion.DataCase, async: false

  alias Salvorion.{Audit, Locations, Organisation, Repo}
  alias Salvorion.Locations.{Area, AssemblyPoint, DepartmentArea, Zone}
  alias Salvorion.Organisation.Department

  Code.require_file("priv/repo/seeds/locations_seed.exs")

  defp counts do
    %{
      assembly_points: Repo.aggregate(AssemblyPoint, :count),
      zones: Repo.aggregate(Zone, :count),
      areas: Repo.aggregate(Area, :count),
      departments: Repo.aggregate(Department, :count),
      links: Repo.aggregate(DepartmentArea, :count)
    }
  end

  test "seeds the guide once and is idempotent on a second run" do
    first = Salvorion.Seeds.Locations.run(quiet: true)
    assert first.assembly_points == %{created: 13, existing: 0}
    assert first.zones == %{created: 13, existing: 0}

    after_first = counts()
    assert after_first.assembly_points == 13
    assert after_first.zones == 13
    assert after_first.areas == 39
    assert after_first.departments == 21
    assert after_first.links == 21

    second = Salvorion.Seeds.Locations.run(quiet: true)
    assert second.assembly_points == %{created: 0, existing: 13}
    assert second.links == %{created: 0, existing: 21}
    assert counts() == after_first
  end

  test "the Steel Building area hosts all five departments" do
    Salvorion.Seeds.Locations.run(quiet: true)

    zone9 = Enum.find(Locations.get_assembly_point_hierarchy(), &(hd(&1.zones).number == 9))
    assert zone9.name == "Hyacinth Chen Nursing School Parking Lot"
    [zone] = zone9.zones
    steel = Enum.find(zone.areas, &String.starts_with?(&1.name, "Steel Building"))

    assert Enum.map(steel.departments, & &1.name) ==
             [
               "Agro Research",
               "Allied Health",
               "Health and Wellness",
               "Quality Management",
               "Research"
             ]
  end

  test "no department is created for halls, buildings, lots or offices" do
    Salvorion.Seeds.Locations.run(quiet: true)
    names = Organisation.list_departments() |> Enum.map(& &1.name)

    for excluded <- [
          "Jamaica Hall",
          "Cedar Hall",
          "Sorenson Hall",
          "Leila Reid Hall",
          "Robinson Hall Building",
          "Administration Block",
          "Old Stores Building",
          "Westico Building",
          "Field View Building",
          "Tai Centre",
          "Gymnatorium",
          "North Campus",
          "Victor Dixon High School",
          "West Indies College Prep. School",
          "NCU Farm",
          "President's Office"
        ] do
      refute Enum.any?(names, &String.contains?(&1, excluded)),
             "unexpected department #{excluded}"
    end
  end

  test "seed writes carry a nil actor" do
    Salvorion.Seeds.Locations.run(quiet: true)
    logs = Audit.list_audit_logs(entity_type: "assembly_point")
    assert length(logs) == 13
    assert Enum.all?(logs, &is_nil(&1.actor_user_id))
  end
end
