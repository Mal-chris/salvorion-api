defmodule Salvorion.RosterFixtures do
  @moduledoc "Test helpers for creating Roster and Organisation entities."

  alias Salvorion.{Organisation, Roster}

  def unique_id_number, do: "TEST-#{System.unique_integer([:positive])}"

  def department_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, dept} =
      Organisation.create_department(
        Enum.into(attrs, %{name: "Department #{n}", code: "DEPT_#{n}"})
      )

    dept
  end

  def programme_fixture(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    faculty_id =
      Map.get_lazy(attrs, :faculty_id, fn ->
        {:ok, f} = Organisation.create_faculty(%{name: "Faculty #{n}", code: "FAC_#{n}"})
        f.id
      end)

    {:ok, programme} =
      Organisation.create_programme(
        attrs
        |> Enum.into(%{name: "Programme #{n}", code: "PROG_#{n}"})
        |> Map.put(:faculty_id, faculty_id)
      )

    programme
  end

  def person_fixture(attrs \\ %{}, opts \\ []) do
    attrs =
      Enum.into(attrs, %{
        type: "staff",
        id_number: unique_id_number(),
        first_name: "Marlow",
        last_name: "Quillbrook",
        source: "roster"
      })

    {:ok, person} = Roster.create_person(attrs, opts)
    person
  end
end
