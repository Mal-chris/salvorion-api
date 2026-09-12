defmodule Salvorion.RosterTest do
  use Salvorion.DataCase, async: true

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.{Audit, Organisation, Roster}
  alias Salvorion.Roster.{Importer, Person, RosterImport}
  alias Salvorion.Roster.Providers.{FileImport, Synthetic}

  @fixture_csv Path.expand("../fixtures/roster_import.csv", __DIR__)

  # ---------------------------------------------------------------------------
  # People
  # ---------------------------------------------------------------------------

  describe "create_person/2 and update_person/3" do
    test "creates, audits with the actor, and updates with before/after" do
      admin = user_fixture()
      dept = department_fixture()

      assert {:ok, person} =
               Roster.create_person(
                 %{
                   type: "staff",
                   id_number: "S-100",
                   first_name: "Tamsin",
                   last_name: "Farrowden",
                   source: "roster",
                   primary_department_id: dept.id
                 },
                 actor: admin
               )

      assert [log] = Audit.list_audit_logs(entity_type: "person", entity_id: person.id)
      assert log.action == "person.created"
      assert log.actor_user_id == admin.id
      assert log.before == nil
      assert log.after["id_number"] == "S-100"

      assert {:ok, updated} = Roster.update_person(person, %{last_name: "Ashgrove"}, actor: admin)
      assert updated.last_name == "Ashgrove"

      assert [update_log, _create_log] =
               Audit.list_audit_logs(entity_type: "person", entity_id: person.id)

      assert update_log.action == "person.updated"
      assert update_log.before["last_name"] == "Farrowden"
      assert update_log.after["last_name"] == "Ashgrove"
    end

    test "requires an id_number for staff and students but not visitors" do
      assert {:error, changeset} =
               Roster.create_person(%{
                 type: "staff",
                 first_name: "A",
                 last_name: "B",
                 source: "roster"
               })

      assert %{id_number: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, visitor} =
               Roster.create_person(%{
                 type: "visitor",
                 first_name: "Sorrel",
                 last_name: "Brambleigh",
                 source: "visitor_registration"
               })

      assert visitor.id_number == nil
    end

    test "reports a non-existent department, programme or area on the changeset" do
      assert {:error, changeset} =
               Roster.create_person(%{
                 type: "staff",
                 id_number: "S-1",
                 first_name: "A",
                 last_name: "B",
                 source: "roster",
                 primary_department_id: Ecto.UUID.generate(),
                 programme_id: Ecto.UUID.generate(),
                 usual_area_id: Ecto.UUID.generate()
               })

      assert %{
               primary_department_id: ["does not exist"],
               programme_id: ["does not exist"],
               usual_area_id: ["does not exist"]
             } = errors_on(changeset)
    end

    test "enforces a unique id_number" do
      person_fixture(%{id_number: "DUP-1"})

      assert {:error, changeset} =
               Roster.create_person(%{
                 type: "student",
                 id_number: "DUP-1",
                 first_name: "A",
                 last_name: "B",
                 source: "roster"
               })

      assert %{id_number: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "get_person_by_id_number/1" do
    test "returns the person, or nil for an unknown, blank or nil number" do
      person = person_fixture(%{id_number: "SCAN-1"})

      assert Roster.get_person_by_id_number("SCAN-1").id == person.id
      assert Roster.get_person_by_id_number("  SCAN-1 ").id == person.id
      assert Roster.get_person_by_id_number("SCAN-does-not-exist") == nil
      assert Roster.get_person_by_id_number("") == nil
      assert Roster.get_person_by_id_number(nil) == nil
    end
  end

  describe "search_people_by_name/1" do
    test "matches partial first or last names case-insensitively" do
      a = person_fixture(%{first_name: "Marlow", last_name: "Quillbrook"})
      b = person_fixture(%{first_name: "Tamsin", last_name: "Marrowby"})
      _c = person_fixture(%{first_name: "Orrin", last_name: "Ashgrove"})

      ids = fn people -> people |> Enum.map(& &1.id) |> Enum.sort() end

      assert ids.(Roster.search_people_by_name("mar")) == ids.([a, b])
      assert ids.(Roster.search_people_by_name("QUILL")) == ids.([a])
      assert ids.(Roster.search_people_by_name("marlow quill")) == ids.([a])
      assert Roster.search_people_by_name("zzz") == []
      assert Roster.search_people_by_name("   ") == []
    end

    test "treats % and _ literally" do
      person_fixture(%{first_name: "Percent", last_name: "Sign"})
      assert Roster.search_people_by_name("%") == []
      assert Roster.search_people_by_name("_") == []
    end
  end

  describe "list_people/1" do
    test "filters by type and by primary or secondary department" do
      d1 = department_fixture()
      d2 = department_fixture()

      primary = person_fixture(%{type: "staff", primary_department_id: d1.id})
      secondary = person_fixture(%{type: "student", primary_department_id: d2.id})
      _other = person_fixture(%{type: "staff", primary_department_id: d2.id})
      {:ok, _} = Roster.register_person_department(secondary, d1)

      ids = fn people -> people |> Enum.map(& &1.id) |> Enum.sort() end

      assert ids.(Roster.list_people(department_id: d1.id)) == ids.([primary, secondary])
      assert ids.(Roster.list_people(department_id: d1.id, type: "student")) == ids.([secondary])
      assert length(Roster.list_people(type: "staff")) == 2
      assert length(Roster.list_people()) == 3
    end
  end

  describe "upsert_person_by_id_number/2" do
    test "creates when the id_number is new and updates when it exists" do
      attrs = %{
        type: "staff",
        id_number: "UP-1",
        first_name: "Kestrel",
        last_name: "Thornbury",
        source: "roster"
      }

      assert {:ok, created} = Roster.upsert_person_by_id_number(attrs)
      assert {:ok, updated} = Roster.upsert_person_by_id_number(%{attrs | last_name: "Wexcombe"})

      assert updated.id == created.id
      assert updated.last_name == "Wexcombe"
      assert Repo.aggregate(Person, :count) == 1

      actions =
        Audit.list_audit_logs(entity_type: "person", entity_id: created.id)
        |> Enum.map(& &1.action)

      assert actions == ["person.updated", "person.created"]
    end

    test "returns a changeset error rather than matching on a blank id_number" do
      assert {:error, changeset} =
               Roster.upsert_person_by_id_number(%{
                 type: "staff",
                 first_name: "A",
                 last_name: "B",
                 source: "roster"
               })

      assert %{id_number: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "person_departments" do
    test "register/remove round-trip with audit rows" do
      admin = user_fixture()
      person = person_fixture()
      dept = department_fixture()

      assert {:ok, membership} = Roster.register_person_department(person, dept, actor: admin)
      assert Roster.get_person_department(person.id, dept.id).id == membership.id

      assert {:error, changeset} = Roster.register_person_department(person.id, dept.id)
      assert %{person_id: ["has already been taken"]} = errors_on(changeset)

      assert {:ok, removed} = Roster.remove_person_department(person, dept, actor: admin)
      assert removed.id == membership.id
      assert Roster.get_person_department(person.id, dept.id) == nil
      assert {:error, :not_found} = Roster.remove_person_department(person, dept)

      assert [removed_log, registered_log] =
               Audit.list_audit_logs(entity_type: "person_department", entity_id: membership.id)

      assert registered_log.action == "person_department.registered"
      assert removed_log.action == "person_department.removed"
      assert removed_log.after == nil
      assert removed_log.before["department_id"] == dept.id
    end

    test "validates that both person and department exist" do
      assert {:error, changeset} =
               Roster.register_person_department(Ecto.UUID.generate(), Ecto.UUID.generate())

      assert %{person_id: ["does not exist"], department_id: ["does not exist"]} =
               errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # Roster imports
  # ---------------------------------------------------------------------------

  describe "roster imports" do
    test "start/complete/list" do
      assert {:ok, import} = Roster.start_roster_import("file_import")
      assert import.completed_at == nil
      assert %DateTime{} = import.started_at

      errors = [%{row: 3, reason: "missing id_number"}]
      assert {:ok, done} = Roster.complete_roster_import(import, 10, errors)
      assert %DateTime{} = done.completed_at
      assert done.total_records == 10
      assert done.error_count == 1
      assert done.errors == %{"rows" => [%{"row" => 3, "reason" => "missing id_number"}]}

      {:ok, later} = Roster.start_roster_import("synthetic")
      assert [%RosterImport{id: a}, %RosterImport{id: b}] = Roster.list_roster_imports()
      assert {a, b} == {later.id, import.id}

      assert [_completed, _started] =
               Audit.list_audit_logs(entity_type: "roster_import", entity_id: import.id)
    end

    test "rejects an unknown provider name" do
      assert {:error, changeset} = Roster.start_roster_import("carrier_pigeon")
      assert %{provider: ["is invalid"]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # Importer (shared by every provider)
  # ---------------------------------------------------------------------------

  describe "Importer.import_record/4" do
    test "resolves codes and reports row-level problems as reasons" do
      dept = department_fixture(%{code: "IMP_DEPT"})
      prog = programme_fixture(%{code: "IMP_PROG"})
      codes = Importer.load_codes()

      base = %{
        type: "student",
        id_number: "IMP-1",
        first_name: "Verity",
        last_name: "Corvane",
        email: nil,
        phone: nil,
        department_code: "IMP_DEPT",
        programme_code: "IMP_PROG"
      }

      assert :ok = Importer.import_record(base, "roster", codes)
      person = Roster.get_person_by_id_number("IMP-1")
      assert person.primary_department_id == dept.id
      assert person.programme_id == prog.id
      assert person.source == "roster"

      assert {:error, "unknown department_code \"NOPE\""} =
               Importer.import_record(%{base | department_code: "NOPE"}, "roster", codes)

      assert {:error, "unknown programme_code \"NOPE\""} =
               Importer.import_record(%{base | programme_code: "NOPE"}, "roster", codes)

      assert {:error, "missing id_number, last_name"} =
               Importer.import_record(%{base | id_number: " ", last_name: ""}, "roster", codes)

      assert {:error, "visitors are registered" <> _} =
               Importer.import_record(%{base | type: "visitor"}, "roster", codes)

      assert {:error, "unknown type \"contractor\"" <> _} =
               Importer.import_record(%{base | type: "contractor"}, "roster", codes)

      assert {:error, "missing type"} =
               Importer.import_record(%{base | type: nil}, "roster", codes)

      assert {:error, "blank row"} =
               Importer.import_record(%{type: "", id_number: nil}, "roster", codes)
    end
  end

  # ---------------------------------------------------------------------------
  # Synthetic provider
  # ---------------------------------------------------------------------------

  describe "Synthetic provider" do
    test "fails cleanly when no departments exist" do
      assert {:error, :no_departments} = Synthetic.run(staff_count: 1, student_count: 1)

      assert [%RosterImport{error_count: 1, total_records: 0, errors: %{"rows" => [row]}}] =
               Roster.list_roster_imports()

      assert row["reason"] =~ "no_departments"
    end

    test "spreads staff over every real department, students over synthetic programmes" do
      depts = for _ <- 1..3, do: department_fixture()

      assert {:ok, %{total: 12, errors: [], import: import}} =
               Synthetic.run(staff_count: 7, student_count: 5)

      assert import.provider == "synthetic"
      assert import.total_records == 12
      assert import.error_count == 0

      people = Roster.list_people()
      assert length(people) == 12
      assert Enum.all?(people, &(&1.source == "synthetic"))
      assert Enum.all?(people, &String.starts_with?(&1.id_number, "SYN-"))

      staff = Enum.filter(people, &(&1.type == "staff"))
      students = Enum.filter(people, &(&1.type == "student"))
      assert length(staff) == 7
      assert length(students) == 5

      per_dept = Enum.frequencies_by(staff, & &1.primary_department_id)
      assert Map.keys(per_dept) |> Enum.sort() == depts |> Enum.map(& &1.id) |> Enum.sort()
      assert Enum.all?(per_dept, fn {_id, n} -> n >= 2 end)

      synthetic_programmes = Organisation.list_programmes()
      assert Enum.all?(synthetic_programmes, &String.starts_with?(&1.code, "SYN-PROG-"))

      assert Enum.all?(
               students,
               &(&1.programme_id in Enum.map(synthetic_programmes, fn p -> p.id end))
             )

      assert Enum.all?(students, &is_nil(&1.primary_department_id))
    end

    test "a second run appends with fresh id_numbers and reuses the placeholder programmes" do
      department_fixture()

      assert {:ok, _} = Synthetic.run(staff_count: 2, student_count: 2)
      first_ids = Roster.list_people() |> Enum.map(& &1.id_number) |> Enum.sort()
      assert first_ids == ["SYN-000001", "SYN-000002", "SYN-000003", "SYN-000004"]
      programme_count = length(Organisation.list_programmes())

      assert {:ok, %{total: 3, errors: []}} = Synthetic.run(staff_count: 1, student_count: 2)

      all_ids = Roster.list_people() |> Enum.map(& &1.id_number) |> Enum.sort()
      assert all_ids == first_ids ++ ["SYN-000005", "SYN-000006", "SYN-000007"]
      assert length(Organisation.list_programmes()) == programme_count
      assert length(Roster.list_roster_imports()) == 2
    end
  end

  # ---------------------------------------------------------------------------
  # File import provider
  # ---------------------------------------------------------------------------

  describe "FileImport provider" do
    test "imports the valid rows of the fixture and reports the broken ones by line" do
      nursing = department_fixture(%{name: "Nursing", code: "NURSING"})
      biology = department_fixture(%{name: "Biology", code: "BIOLOGY"})

      assert {:ok, %{total: 8, errors: errors, import: import}} =
               FileImport.run(path: @fixture_csv)

      assert import.provider == "file_import"
      assert import.total_records == 8
      assert import.error_count == 5
      assert %DateTime{} = import.completed_at

      assert errors == [
               %{row: 5, reason: "missing id_number"},
               %{row: 6, reason: "unknown department_code \"NOT_A_DEPARTMENT\""},
               %{
                 row: 7,
                 reason: "visitors are registered on the spot, not imported from a roster"
               },
               %{row: 8, reason: "unknown programme_code \"NOT_A_PROGRAMME\""},
               %{row: 9, reason: "missing first_name"}
             ]

      people = Roster.list_people()
      assert length(people) == 3
      assert Enum.all?(people, &(&1.source == "roster"))

      marlow = Roster.get_person_by_id_number("FIX-0001")
      assert marlow.first_name == "Marlow"
      assert marlow.primary_department_id == nursing.id
      assert marlow.email == "marlow.quillbrook@example.invalid"
      assert marlow.phone == "876-555-0101"

      assert Roster.get_person_by_id_number("FIX-0002").primary_department_id == biology.id
      assert Roster.get_person_by_id_number("FIX-0003").type == "student"
      assert Roster.get_person_by_id_number("FIX-0005") == nil
    end

    test "re-importing the same file updates rather than duplicates" do
      department_fixture(%{code: "NURSING"})
      department_fixture(%{code: "BIOLOGY"})

      assert {:ok, %{total: 8}} = FileImport.run(path: @fixture_csv)
      assert {:ok, %{total: 8, errors: errors}} = FileImport.run(path: @fixture_csv)
      assert length(errors) == 5
      assert length(Roster.list_people()) == 3
    end

    test "fails the run, not the process, for an unreadable file or missing columns" do
      assert {:error, reason} = FileImport.run(path: "/nonexistent/roster.csv")
      assert reason =~ "could not read"

      assert [%RosterImport{total_records: 0, error_count: 1}] = Roster.list_roster_imports()

      path = Path.join(System.tmp_dir!(), "salvorion-bad-header-#{System.unique_integer()}.csv")
      File.write!(path, "first_name,last_name\nA,B\n")
      on_exit(fn -> File.rm(path) end)

      assert {:error, "missing columns: type, id_number"} = FileImport.run(path: path)
    end

    test "fetch_records/1 tolerates a BOM, header case, and short rows" do
      path = Path.join(System.tmp_dir!(), "salvorion-bom-#{System.unique_integer()}.csv")

      File.write!(
        path,
        <<0xEF, 0xBB, 0xBF>> <>
          "Type,ID_Number,First_Name,Last_Name\nstaff,X-1,A,B\nstudent,X-2\n"
      )

      on_exit(fn -> File.rm(path) end)

      assert {:ok, [first, second]} = FileImport.fetch_records(path: path)
      assert first.type == "staff" and first.id_number == "X-1" and first.department_code == nil
      assert second.first_name == nil
    end
  end
end
