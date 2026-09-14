# Prompt 3: Organisation and Locations Contexts, OSH Seed Data

**Document:** 15 of the project record
**Corresponds to:** Technical Foundation (03), Stage A item 4 (OSH seed data) and Stage B item 6 (Organisation/Locations modules), taken together since the seed data needs context functions to insert through, not raw `Repo.insert` calls
**Environment:** WSL2 Ubuntu, inside `~/salvorion`
**Prepared:** 12 September 2026

---

## Scope note before you run this

This prompt does **not** add HTTP routes or controllers for these two contexts. It builds the context modules (the public API other code calls) and uses them to seed real data. Routes come later, alongside the admin screens in Document 11, once there's a client to call them. Verification here happens through a script run with `mix run`, not curl.

Reference documents are now in `docs/` (`06-erd-and-data-dictionary.md` for the schema, `10-security-design.md` for RBAC, `13-consistency-audit.md` for what changed after review) — tell Claude Code to read them directly rather than relying on the prompt's paraphrase.

---

## The prompt

```
This is the third step in building Salvorion. Prompts 1 and 2 (complete)
scaffolded the project and built Accounts/Audit with RS256 auth. This
prompt builds the Organisation and Locations contexts and seeds them with
real data from NCU's Emergency Assembly Point Guide — not synthetic data,
since this particular dataset is real and was provided by OSH.

Before starting, read docs/06-erd-and-data-dictionary.md (the Organisation
and Locations entities, and the department_areas many-to-many join),
docs/10-security-design.md section 1 (RBAC — Organisation/Locations
management is Yes for both admin and osh_officer, per the resolution in
docs/13-consistency-audit.md, finding 1.3), and follow the same patterns
already established in lib/salvorion/accounts.ex: every create/update
takes an `opts` keyword list with an `:actor`, and every mutation calls
Salvorion.Audit.record/1 in the same transaction via Ecto.Multi.

TASK 1: The Organisation context
Create lib/salvorion/organisation.ex (schemas already exist in
lib/salvorion/organisation/) exposing:
- create_faculty/2, list_faculties/0, get_faculty!/1, update_faculty/3
- create_department/2, list_departments/0, get_department!/1,
  update_department/3 (a department's faculty_id is optional — do not
  require it, per the schema's own changeset)
- create_programme/2, list_programmes/0, get_programme!/1
- get_department_with_areas!/1 — a department preloaded with its
  many-to-many areas (via the join in Task 2), for the future admin
  screen described in Document 11, section 2.5

TASK 2: The Locations context
Create lib/salvorion/locations.ex (schemas already exist in
lib/salvorion/locations/) exposing:
- create_assembly_point/2, list_assembly_points/0
- create_zone/2 (validates the zone belongs to an assembly point),
  list_zones/0 ordered by :number
- create_area/2 (validates the area belongs to a zone),
  list_areas_for_zone/1
- link_department_to_area/3 and unlink_department_from_area/3 — manage
  rows in department_areas (Ecto schema:
  Salvorion.Locations.DepartmentArea)
- get_assembly_point_hierarchy/0 — returns every assembly point with its
  zones, each zone with its areas, each area with its linked
  departments preloaded, structured for a future admin screen and for
  reuse in this prompt's own seed verification (Task 4)

TASK 3: Audit integration
Every create/update function in both contexts above must record an audit
entry (action, entity_type, entity_id, before, after) exactly as
lib/salvorion/accounts.ex already does. Reuse its pattern; do not
reinvent a second convention.

TASK 4: Seed the real OSH Emergency Assembly Point Guide data
This is real data from NCU's official guide, not placeholder or
synthetic data. Seed it exactly as given below — do not paraphrase,
merge, or "clean up" any entry, even where two entries look like they
might overlap (noted explicitly where that happens; NCU has not yet
confirmed how to resolve those, so both are seeded as written).

Create one AssemblyPoint per zone below (13 total), one Zone per
assembly point (number as given), and one Area per bullet under that
zone (area name = the bullet text, verbatim).

  Zone 1 — Assembly point: "Administration Parking Lot"
    Areas: Jamaica Hall; Annex Complex/ Counselling Department;
    Vic Burn Lab; Sorenson Hall & Sorenson Hall Basement;
    President's Office; Communication Studies Department; Cedar Hall;
    Solomon Harriot Lecture Theatre; Fine Arts Department

  Zone 2 — Assembly point: "Robinson Hall Greens (beside the gazebo
    across from Robinson Hall)"
    Areas: Administration Block

  Zone 3 — Assembly point: "Sorenson Hall Greens (the green space
    between the Vicburn Lab and the cafeteria)"
    Areas: Hiram S. Walters Resource Centre; Robinson Hall Building

  Zone 4 — Assembly point: "Main Parking Lot"
    Areas: Security and Risk Management; NCU Press;
    1st 2nd 3rd Floor Robinson Hall; Custodial Services;
    1st & 2nd Floor Back of Hiram S. Walters Resource Centre;
    Medical Technology Department; Department of Teacher Education;
    Biology Department; Music Department; Leila Reid Hall;
    Old Stores Building

  Zone 5 — Assembly point: "Campbell's Sports Centre Greens"
    Areas: Gymnatorium; Field View Building;
    Computer Information Sciences; Stores & Transportation

  Zone 6 — Assembly point: "Gymnatorium Paved Lawn (closer to the
    playfield end)"
    Areas: NCU Day Care

  Zone 7 — Assembly point: "Tai Centre Parking Lot"
    Areas: West Indies College Prep. School

  Zone 8 — Assembly point: "Health & Wellness Parking Lot"
    Areas: Nursing Department

  Zone 9 — Assembly point: "Hyacinth Chen Nursing School Parking Lot"
    Areas: Steel Building — Health and Wellness, Quality Management,
    Research, Allied Health, Agro Research (SEE NOTE BELOW — this one
    area hosts five departments); Nutrition Lab; Dental Department;
    NCU Media Department

  Zone 10 — Assembly point: "West Indies Prep. Parking Lot"
    Areas: Tai Centre; Westico Building

  Zone 11 — Assembly point: "North Campus Greens (vicinity of the gate)"
    Areas: North Campus

  Zone 12 — Assembly point: "Victor Dixon High School Playfield"
    Areas: Victor Dixon High School

  Zone 13 — Assembly point: "Farm Open Field"
    Areas: NCU Farm

NOTE on known overlaps (seed both as written, do not merge): "Robinson
Hall Building" (Zone 3) and "1st 2nd 3rd Floor Robinson Hall" (Zone 4)
may refer to overlapping physical space. Likewise "Hiram S. Walters
Resource Centre" (Zone 3) and "1st & 2nd Floor Back of Hiram S. Walters
Resource Centre" (Zone 4). Add a code comment in the seed file at both
pairs noting this is an open question for OSH to clarify (see
docs/02-proposal-for-osh-review.md and docs/05-srs.md, Appendix A) —
do not attempt to resolve it yourself.

Department extraction rule (do not invent departments beyond this rule):
Create a Department record, with no faculty_id (faculties are not yet
known — see Document 01, section 9), ONLY for:
  (a) an area bullet whose name unambiguously names a department or
      teaching/administrative unit, e.g. "Communication Studies
      Department", "Fine Arts Department" (create as "Fine Arts", the
      area is separately named "Fine Arts Department" — use your
      judgement to strip the redundant word "Department" from the
      Department record's own name where the area name already carries
      it, but do NOT rename the Area), "Medical Technology Department",
      "Department of Teacher Education", "Biology Department", "Music
      Department", "Nursing Department", "Dental Department", "NCU
      Media Department", "Computer Information Sciences", "Security and
      Risk Management", "NCU Press", "Custodial Services", "Nutrition
      Lab", "Stores & Transportation", "NCU Day Care";
  (b) the five units named inside the Steel Building bullet in Zone 9:
      Health and Wellness, Quality Management, Research, Allied Health,
      Agro Research — create all five as separate Department records
      and link ALL FIVE to that one Area via department_areas. This is
      the concrete example of the many-to-many relationship the ERD
      documents.
Do NOT create a Department for halls, dormitories, parking lots,
buildings named only by proper noun (Jamaica Hall, Cedar Hall, Sorenson
Hall, Leila Reid Hall, Robinson Hall Building, Administration Block,
Old Stores Building, Westico Building, Field View Building, Tai Centre,
Gymnatorium, North Campus, Victor Dixon High School, West Indies College
Prep. School, NCU Farm), or for offices like the President's Office —
these remain Areas with no linked Department until OSH confirms whether
they should have one. Link every other department created in (a) to its
own single Area via department_areas (a 1:1 link, but still going
through the many-to-many table, not a shortcut).

Write this as priv/repo/seeds/locations_seed.exs (a separate file from
the existing priv/repo/seeds.exs, which handles the admin user), called
from priv/repo/seeds.exs. Use the context functions from Tasks 1 and 2
— do not call Repo.insert directly for any of this data. Make the seed
idempotent (safe to run twice without duplicating rows) — check for an
existing assembly point by name before creating, same for zones by
number, areas by name+zone, departments by name.

VERIFICATION
After completing all tasks, tell me explicitly:
1. mix compile output, zero new warnings.
2. Row counts after seeding: assembly_points, zones, areas, departments,
   department_areas — and confirm 13 assembly points, 13 zones.
3. Run the seed a second time and confirm row counts are unchanged
   (proves idempotency).
4. Print the full result of get_assembly_point_hierarchy/0 for Zone 9
   specifically, showing the Steel Building area with all five
   departments listed under it.
5. Confirm, by listing them, that no Department record was created for
   any of the hall/building/parking-lot names in the "do NOT create"
   list.
6. Confirm both audit_logs rows exist for one sample create (e.g. the
   first assembly point), showing actor_user_id is nil (system seed,
   not an authenticated user — this is the second and last case, along
   with the bootstrap admin, where a nil actor is correct).
7. A list of every file created or modified.

Stop after verification. Do not build routes/controllers for these
contexts, and do not start the Roster context yet.
```

---

## What to check yourself

1. **Read the hierarchy dump for Zone 9 yourself.** This is the one part of the seed with real design significance, confirm five distinct Department rows, all linked to the one Steel Building Area, not five separate areas or a single merged department.
2. **Spot-check the "do NOT create" list against item 5's output.** If a Department named "Robinson Hall" or "Cedar Hall" shows up, that's a rule violation worth catching now, before it propagates into fake compliance-reporting categories later.
3. **Confirm idempotency actually matters here**: ask yourself what would happen if this seed ran a third time on a machine that already has the data — item 3 tests twice, not three times, but the logic being name/number-lookup-then-create should hold for any number of runs. If you want to be thorough, run it a third time yourself.
4. **Skim the code comments at the two flagged overlaps** (Robinson Hall, Hiram S. Walters) and confirm they read as a note to a future reader, not a silent guess dressed up as fact.
