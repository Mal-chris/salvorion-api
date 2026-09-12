defmodule Salvorion.OrganisationTest do
  use Salvorion.DataCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.{Audit, Locations, Organisation}

  describe "faculties" do
    test "create_faculty/2 creates and audits with the actor" do
      admin = user_fixture()

      assert {:ok, faculty} =
               Organisation.create_faculty(%{name: "Science", code: "SCI"}, actor: admin)

      assert [log] = Audit.list_audit_logs(entity_type: "faculty", entity_id: faculty.id)
      assert log.action == "faculty.created"
      assert log.actor_user_id == admin.id
      assert log.before == nil
      assert log.after["code"] == "SCI"

      assert Organisation.get_faculty!(faculty.id).id == faculty.id
      assert [%{id: id}] = Organisation.list_faculties()
      assert id == faculty.id
    end

    test "create_faculty/2 requires name and code and a unique code" do
      assert {:error, changeset} = Organisation.create_faculty(%{})
      assert %{name: ["can't be blank"], code: ["can't be blank"]} = errors_on(changeset)

      {:ok, _} = Organisation.create_faculty(%{name: "A", code: "DUP"})
      assert {:error, changeset} = Organisation.create_faculty(%{name: "B", code: "DUP"})
      assert %{code: ["has already been taken"]} = errors_on(changeset)
    end

    test "update_faculty/3 audits before and after" do
      admin = user_fixture()
      {:ok, faculty} = Organisation.create_faculty(%{name: "Old", code: "OLD"}, actor: admin)

      assert {:ok, updated} = Organisation.update_faculty(faculty, %{name: "New"}, actor: admin)
      assert updated.name == "New"

      assert [log] = Audit.list_audit_logs(action: "faculty.updated", entity_id: faculty.id)
      assert log.before["name"] == "Old"
      assert log.after["name"] == "New"
      assert log.actor_user_id == admin.id
    end
  end

  describe "departments" do
    test "create_department/2 does not require a faculty" do
      assert {:ok, dept} = Organisation.create_department(%{name: "Biology", code: "BIOLOGY"})
      assert dept.faculty_id == nil
      assert Organisation.get_department_by_name("Biology").id == dept.id
      assert Organisation.get_department_by_name("Nope") == nil
      assert [%{action: "department.created"}] = Audit.list_audit_logs(entity_id: dept.id)
    end

    test "create_department/2 accepts an existing faculty and rejects an unknown one" do
      {:ok, faculty} = Organisation.create_faculty(%{name: "Science", code: "SCI"})

      assert {:ok, dept} =
               Organisation.create_department(%{name: "Bio", code: "BIO", faculty_id: faculty.id})

      assert dept.faculty_id == faculty.id

      assert {:error, changeset} =
               Organisation.create_department(%{
                 name: "X",
                 code: "X",
                 faculty_id: Ecto.UUID.generate()
               })

      assert %{faculty_id: [_]} = errors_on(changeset)
    end

    test "update_department/3 changes fields and audits" do
      admin = user_fixture()
      {:ok, dept} = Organisation.create_department(%{name: "Old", code: "OLD"}, actor: admin)

      assert {:ok, updated} =
               Organisation.update_department(dept, %{code: "NEW"}, actor: admin)

      assert updated.code == "NEW"
      assert [log] = Audit.list_audit_logs(action: "department.updated", entity_id: dept.id)
      assert log.before["code"] == "OLD" and log.after["code"] == "NEW"
    end

    test "list_departments/0 is ordered by name" do
      {:ok, _} = Organisation.create_department(%{name: "Zoology", code: "ZOO"})
      {:ok, _} = Organisation.create_department(%{name: "Art", code: "ART"})
      assert ["Art", "Zoology"] = Organisation.list_departments() |> Enum.map(& &1.name)
    end

    test "get_department_with_areas!/1 preloads areas via department_areas" do
      {:ok, dept} = Organisation.create_department(%{name: "Research", code: "RESEARCH"})
      {:ok, ap} = Locations.create_assembly_point(%{name: "AP"})
      {:ok, zone} = Locations.create_zone(%{number: 901, assembly_point_id: ap.id})
      {:ok, a1} = Locations.create_area(%{name: "Steel Building", zone_id: zone.id})
      {:ok, a2} = Locations.create_area(%{name: "Annex", zone_id: zone.id})
      {:ok, _} = Locations.link_department_to_area(dept, a1)
      {:ok, _} = Locations.link_department_to_area(dept, a2)

      loaded = Organisation.get_department_with_areas!(dept.id)
      assert Enum.map(loaded.areas, & &1.name) == ["Annex", "Steel Building"]
      assert Enum.all?(loaded.areas, &(&1.zone.id == zone.id))

      assert_raise Ecto.NoResultsError, fn ->
        Organisation.get_department_with_areas!(Ecto.UUID.generate())
      end
    end
  end

  describe "programmes" do
    test "create_programme/2 requires a faculty and audits" do
      admin = user_fixture()
      {:ok, faculty} = Organisation.create_faculty(%{name: "Science", code: "SCI"})

      assert {:error, changeset} = Organisation.create_programme(%{name: "BSc", code: "BSC"})
      assert %{faculty_id: ["can't be blank"]} = errors_on(changeset)

      assert {:ok, programme} =
               Organisation.create_programme(
                 %{name: "BSc Biology", code: "BSC-BIO", faculty_id: faculty.id},
                 actor: admin
               )

      assert Organisation.get_programme!(programme.id).faculty_id == faculty.id
      assert [%{id: id}] = Organisation.list_programmes()
      assert id == programme.id

      assert [log] = Audit.list_audit_logs(entity_type: "programme", entity_id: programme.id)
      assert log.action == "programme.created" and log.actor_user_id == admin.id
    end
  end
end
