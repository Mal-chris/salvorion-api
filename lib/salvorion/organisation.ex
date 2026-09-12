defmodule Salvorion.Organisation do
  @moduledoc """
  The Organisation context: faculties, departments and programmes
  (FR-LOC-03). Departments are linked to physical areas through the
  `department_areas` join managed by `Salvorion.Locations`.

  Every create/update takes an `opts` keyword list whose `:actor` names
  the authenticated user performing the action; the change and its audit
  row are written in one transaction via `Salvorion.Audit.Multi`, the
  same convention as `Salvorion.Accounts`. Pass no actor only where there
  is genuinely no acting user (the OSH guide seed).

  A department's `faculty_id` is optional: faculties are not yet known
  (Document 01, section 9), so departments seeded from the OSH guide have
  none until OSH confirms the structure.
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [audit: 7, run_audited: 2]

  alias Ecto.Multi
  alias Salvorion.Locations.Area
  alias Salvorion.Organisation.{Department, Faculty, Programme}
  alias Salvorion.Repo

  @type opts :: Salvorion.Audit.Multi.opts()

  # ---------------------------------------------------------------------------
  # Faculties
  # ---------------------------------------------------------------------------

  @doc "Creates a faculty. `attrs` needs `:name` and `:code`."
  @spec create_faculty(map, opts) :: {:ok, %Faculty{}} | {:error, Ecto.Changeset.t()}
  def create_faculty(attrs, opts \\ []) do
    Multi.new()
    |> Multi.insert(:faculty, Faculty.changeset(%Faculty{}, attrs))
    |> audit(:faculty, "faculty.created", "faculty", nil, &faculty_snapshot/1, opts)
    |> run_audited(:faculty)
  end

  @spec list_faculties() :: [%Faculty{}]
  def list_faculties, do: Repo.all(from f in Faculty, order_by: f.name)

  @spec get_faculty!(binary) :: %Faculty{}
  def get_faculty!(id), do: Repo.get!(Faculty, id)

  @doc "Finds a faculty by exact code, or nil."
  @spec get_faculty_by_code(String.t()) :: %Faculty{} | nil
  def get_faculty_by_code(code) when is_binary(code), do: Repo.get_by(Faculty, code: code)

  @spec update_faculty(%Faculty{}, map, opts) ::
          {:ok, %Faculty{}} | {:error, Ecto.Changeset.t()}
  def update_faculty(%Faculty{} = faculty, attrs, opts \\ []) do
    before = faculty_snapshot(faculty)

    Multi.new()
    |> Multi.update(:faculty, Faculty.changeset(faculty, attrs))
    |> audit(:faculty, "faculty.updated", "faculty", before, &faculty_snapshot/1, opts)
    |> run_audited(:faculty)
  end

  # ---------------------------------------------------------------------------
  # Departments
  # ---------------------------------------------------------------------------

  @doc """
  Creates a department. `attrs` needs `:name` and `:code`; `:faculty_id`
  is optional (the schema does not require it).
  """
  @spec create_department(map, opts) :: {:ok, %Department{}} | {:error, Ecto.Changeset.t()}
  def create_department(attrs, opts \\ []) do
    Multi.new()
    |> Multi.insert(:department, Department.changeset(%Department{}, attrs))
    |> audit(:department, "department.created", "department", nil, &department_snapshot/1, opts)
    |> run_audited(:department)
  end

  @spec list_departments() :: [%Department{}]
  def list_departments, do: Repo.all(from d in Department, order_by: d.name)

  @spec get_department!(binary) :: %Department{}
  def get_department!(id), do: Repo.get!(Department, id)

  @doc "Finds a department by exact name, or nil. Used by the seed for idempotency."
  @spec get_department_by_name(String.t()) :: %Department{} | nil
  def get_department_by_name(name) when is_binary(name), do: Repo.get_by(Department, name: name)

  @doc "Finds a department by exact code, or nil. Roster imports resolve `department_code` this way."
  @spec get_department_by_code(String.t()) :: %Department{} | nil
  def get_department_by_code(code) when is_binary(code), do: Repo.get_by(Department, code: code)

  @spec update_department(%Department{}, map, opts) ::
          {:ok, %Department{}} | {:error, Ecto.Changeset.t()}
  def update_department(%Department{} = department, attrs, opts \\ []) do
    before = department_snapshot(department)

    Multi.new()
    |> Multi.update(:department, Department.changeset(department, attrs))
    |> audit(
      :department,
      "department.updated",
      "department",
      before,
      &department_snapshot/1,
      opts
    )
    |> run_audited(:department)
  end

  @doc """
  A department with its many-to-many `areas` preloaded (each area with its
  zone), for the organisation admin screen (Document 11, section 2.5).
  Raises if the department does not exist.
  """
  @spec get_department_with_areas!(binary) :: %Department{}
  def get_department_with_areas!(id) do
    areas_query = from a in Area, order_by: a.name, preload: :zone

    Department
    |> Repo.get!(id)
    |> Repo.preload(areas: areas_query)
  end

  # ---------------------------------------------------------------------------
  # Programmes
  # ---------------------------------------------------------------------------

  @doc "Creates a programme. `attrs` needs `:name`, `:code` and `:faculty_id`."
  @spec create_programme(map, opts) :: {:ok, %Programme{}} | {:error, Ecto.Changeset.t()}
  def create_programme(attrs, opts \\ []) do
    Multi.new()
    |> Multi.insert(:programme, Programme.changeset(%Programme{}, attrs))
    |> audit(:programme, "programme.created", "programme", nil, &programme_snapshot/1, opts)
    |> run_audited(:programme)
  end

  @spec list_programmes() :: [%Programme{}]
  def list_programmes, do: Repo.all(from p in Programme, order_by: p.name)

  @spec get_programme!(binary) :: %Programme{}
  def get_programme!(id), do: Repo.get!(Programme, id)

  @doc "Finds a programme by exact code, or nil. Roster imports resolve `programme_code` this way."
  @spec get_programme_by_code(String.t()) :: %Programme{} | nil
  def get_programme_by_code(code) when is_binary(code), do: Repo.get_by(Programme, code: code)

  # ---------------------------------------------------------------------------
  # Audit snapshots (what lands in audit_logs.before/after)
  # ---------------------------------------------------------------------------

  defp faculty_snapshot(%Faculty{} = f), do: %{id: f.id, name: f.name, code: f.code}

  defp department_snapshot(%Department{} = d),
    do: %{id: d.id, name: d.name, code: d.code, faculty_id: d.faculty_id}

  defp programme_snapshot(%Programme{} = p),
    do: %{id: p.id, name: p.name, code: p.code, faculty_id: p.faculty_id}
end
