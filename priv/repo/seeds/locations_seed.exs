# Seeds the assembly point / zone / area hierarchy and the departments named
# in NCU's OSH Emergency Assembly Point Guide. This is REAL data provided by
# OSH, not placeholder data: entries are seeded exactly as written in the
# guide, even where two entries may overlap (see the OPEN QUESTION comments
# below). Nothing here is merged, paraphrased or "cleaned up".
#
# Invoked from priv/repo/seeds.exs:
#
#     Code.require_file("seeds/locations_seed.exs", __DIR__)
#     Salvorion.Seeds.Locations.run()
#
# Idempotent: assembly points are looked up by name, zones by number, areas by
# name within their zone, departments by name, and department/area links by
# pair, so running it twice creates nothing new.
#
# Every write goes through the Organisation and Locations context functions
# with no :actor: there is no authenticated user during seeding, so the audit
# rows carry actor_user_id = nil. This and the bootstrap admin in seeds.exs
# are the only two places where a nil actor is correct.

defmodule Salvorion.Seeds.Locations do
  alias Salvorion.{Locations, Organisation}

  # {zone number, assembly point name, [area names verbatim from the guide]}
  @guide [
    {1, "Administration Parking Lot",
     [
       "Jamaica Hall",
       "Annex Complex/ Counselling Department",
       "Vic Burn Lab",
       "Sorenson Hall & Sorenson Hall Basement",
       "President's Office",
       "Communication Studies Department",
       "Cedar Hall",
       "Solomon Harriot Lecture Theatre",
       "Fine Arts Department"
     ]},
    {2, "Robinson Hall Greens (beside the gazebo across from Robinson Hall)",
     ["Administration Block"]},
    {3, "Sorenson Hall Greens (the green space between the Vicburn Lab and the cafeteria)",
     [
       # OPEN QUESTION for OSH: "Hiram S. Walters Resource Centre" (Zone 3) and
       # "1st & 2nd Floor Back of Hiram S. Walters Resource Centre" (Zone 4) may
       # refer to overlapping physical space. Both are seeded as written until
       # OSH clarifies (docs/02-proposal-for-osh-review.md section 6, question 6;
       # docs/05-srs.md Appendix A). Do not merge them here.
       "Hiram S. Walters Resource Centre",
       # OPEN QUESTION for OSH: "Robinson Hall Building" (Zone 3) and
       # "1st 2nd 3rd Floor Robinson Hall" (Zone 4) may refer to overlapping
       # physical space. Both are seeded as written until OSH clarifies (same
       # references as above). Do not merge them here.
       "Robinson Hall Building"
     ]},
    {4, "Main Parking Lot",
     [
       "Security and Risk Management",
       "NCU Press",
       # OPEN QUESTION for OSH: possible overlap with "Robinson Hall Building"
       # in Zone 3 (see the comment there). Seeded as written.
       "1st 2nd 3rd Floor Robinson Hall",
       "Custodial Services",
       # OPEN QUESTION for OSH: possible overlap with "Hiram S. Walters Resource
       # Centre" in Zone 3 (see the comment there). Seeded as written.
       "1st & 2nd Floor Back of Hiram S. Walters Resource Centre",
       "Medical Technology Department",
       "Department of Teacher Education",
       "Biology Department",
       "Music Department",
       "Leila Reid Hall",
       "Old Stores Building"
     ]},
    {5, "Campbell's Sports Centre Greens",
     [
       "Gymnatorium",
       "Field View Building",
       "Computer Information Sciences",
       "Stores & Transportation"
     ]},
    {6, "Gymnatorium Paved Lawn (closer to the playfield end)", ["NCU Day Care"]},
    {7, "Tai Centre Parking Lot", ["West Indies College Prep. School"]},
    {8, "Health & Wellness Parking Lot", ["Nursing Department"]},
    {9, "Hyacinth Chen Nursing School Parking Lot",
     [
       # One area housing five departments: the concrete many-to-many case
       # documented in the ERD (docs/06, section 2). See @departments below.
       "Steel Building — Health and Wellness, Quality Management, Research, Allied Health, Agro Research",
       "Nutrition Lab",
       "Dental Department",
       "NCU Media Department"
     ]},
    {10, "West Indies Prep. Parking Lot", ["Tai Centre", "Westico Building"]},
    {11, "North Campus Greens (vicinity of the gate)", ["North Campus"]},
    {12, "Victor Dixon High School Playfield", ["Victor Dixon High School"]},
    {13, "Farm Open Field", ["NCU Farm"]}
  ]

  # Departments extracted from the guide, per the extraction rule agreed for
  # this seed: only bullets that unambiguously name a department or a
  # teaching/administrative unit, plus the five units inside the Steel
  # Building bullet. Halls, dormitories, parking lots, buildings named only by
  # a proper noun, and offices (President's Office) get NO department until
  # OSH confirms whether they should have one.
  #
  # {department name, {zone number, area name it is linked to}}
  # Where the area name already carries the word "Department", the department
  # record drops it; the Area keeps its verbatim name.
  @steel_building {9,
                   "Steel Building — Health and Wellness, Quality Management, Research, Allied Health, Agro Research"}

  @departments [
    # (a) bullets that name a unit
    {"Communication Studies", {1, "Communication Studies Department"}},
    {"Fine Arts", {1, "Fine Arts Department"}},
    {"Security and Risk Management", {4, "Security and Risk Management"}},
    {"NCU Press", {4, "NCU Press"}},
    {"Custodial Services", {4, "Custodial Services"}},
    {"Medical Technology", {4, "Medical Technology Department"}},
    {"Teacher Education", {4, "Department of Teacher Education"}},
    {"Biology", {4, "Biology Department"}},
    {"Music", {4, "Music Department"}},
    {"Computer Information Sciences", {5, "Computer Information Sciences"}},
    {"Stores & Transportation", {5, "Stores & Transportation"}},
    {"NCU Day Care", {6, "NCU Day Care"}},
    {"Nursing", {8, "Nursing Department"}},
    {"Nutrition Lab", {9, "Nutrition Lab"}},
    {"Dental", {9, "Dental Department"}},
    {"NCU Media", {9, "NCU Media Department"}},
    # (b) the five units inside the Steel Building bullet, all linked to that
    # one area
    {"Health and Wellness", @steel_building},
    {"Quality Management", @steel_building},
    {"Research", @steel_building},
    {"Allied Health", @steel_building},
    {"Agro Research", @steel_building}
  ]

  @doc "Seeds the guide. Returns a summary map of created/existing counts."
  def run(opts \\ []) do
    log = if Keyword.get(opts, :quiet, false), do: fn _ -> :ok end, else: &IO.puts/1

    counts =
      Enum.reduce(@guide, new_counts(), fn {number, ap_name, area_names}, counts ->
        {ap, counts} = ensure_assembly_point(ap_name, counts)
        {zone, counts} = ensure_zone(number, ap, counts)

        Enum.reduce(area_names, counts, fn area_name, counts ->
          {_area, counts} = ensure_area(zone, area_name, counts)
          counts
        end)
      end)

    counts =
      Enum.reduce(@departments, counts, fn {dept_name, {zone_number, area_name}}, counts ->
        {dept, counts} = ensure_department(dept_name, counts)
        zone = Locations.get_zone_by_number(zone_number) || raise "zone #{zone_number} missing"

        area =
          Locations.get_area_by_name(zone.id, area_name) ||
            raise "area #{inspect(area_name)} missing in zone #{zone_number}"

        {_link, counts} = ensure_link(dept, area, counts)
        counts
      end)

    log.("""
    [seeds] OSH Emergency Assembly Point Guide
      assembly points: #{fmt(counts.assembly_points)}
      zones:           #{fmt(counts.zones)}
      areas:           #{fmt(counts.areas)}
      departments:     #{fmt(counts.departments)}
      dept/area links: #{fmt(counts.links)}
    """)

    counts
  end

  @doc "The guide data as seeded, for tests and verification."
  def guide, do: @guide
  def departments, do: @departments

  # -- ensure_* helpers: look up first, create only if absent --------------

  defp ensure_assembly_point(name, counts) do
    case Locations.get_assembly_point_by_name(name) do
      nil ->
        {:ok, ap} = Locations.create_assembly_point(%{name: name})
        {ap, bump(counts, :assembly_points, :created)}

      ap ->
        {ap, bump(counts, :assembly_points, :existing)}
    end
  end

  defp ensure_zone(number, ap, counts) do
    case Locations.get_zone_by_number(number) do
      nil ->
        {:ok, zone} = Locations.create_zone(%{number: number, assembly_point_id: ap.id})
        {zone, bump(counts, :zones, :created)}

      zone ->
        {zone, bump(counts, :zones, :existing)}
    end
  end

  defp ensure_area(zone, name, counts) do
    case Locations.get_area_by_name(zone.id, name) do
      nil ->
        {:ok, area} = Locations.create_area(%{name: name, zone_id: zone.id})
        {area, bump(counts, :areas, :created)}

      area ->
        {area, bump(counts, :areas, :existing)}
    end
  end

  defp ensure_department(name, counts) do
    case Organisation.get_department_by_name(name) do
      nil ->
        {:ok, dept} = Organisation.create_department(%{name: name, code: code_for(name)})
        {dept, bump(counts, :departments, :created)}

      dept ->
        {dept, bump(counts, :departments, :existing)}
    end
  end

  defp ensure_link(dept, area, counts) do
    case Locations.get_link(dept.id, area.id) do
      nil ->
        {:ok, link} = Locations.link_department_to_area(dept.id, area.id)
        {link, bump(counts, :links, :created)}

      link ->
        {link, bump(counts, :links, :existing)}
    end
  end

  # departments.code is required and unique, but the guide gives no codes.
  # Derive a stable, readable code from the name (e.g. "Stores &
  # Transportation" -> "STORES_TRANSPORTATION") until NCU supplies official
  # codes; an admin can change them later via Organisation.update_department/3.
  defp code_for(name) do
    name
    |> String.upcase()
    |> String.replace(~r/[^A-Z0-9]+/, "_")
    |> String.trim("_")
  end

  defp new_counts do
    Map.new([:assembly_points, :zones, :areas, :departments, :links], fn k ->
      {k, %{created: 0, existing: 0}}
    end)
  end

  defp bump(counts, key, which), do: update_in(counts, [key, which], &(&1 + 1))

  defp fmt(%{created: c, existing: e}), do: "#{c} created, #{e} already present"
end
