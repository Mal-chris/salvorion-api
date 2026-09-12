defmodule Salvorion.Locations do
  @moduledoc """
  The Locations context: assembly points, the zones that report to them,
  the areas inside each zone, and the many-to-many link between areas and
  departments (FR-LOC-01, FR-LOC-02). The hierarchy mirrors the OSH
  Emergency Assembly Point Guide: one assembly point receives one or more
  zones, each zone groups areas, and an area may house several departments
  (the Steel Building) while a department may occupy areas in several zones.

  Every create/update/link takes an `opts` keyword list whose `:actor`
  names the authenticated user performing the action; the change and its
  audit row are written in one transaction via `Salvorion.Audit.Multi`,
  the same convention as `Salvorion.Accounts`. Pass no actor only where
  there is genuinely no acting user (the OSH guide seed).
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [audit: 7, run_audited: 2]

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Salvorion.Locations.{Area, AssemblyPoint, DepartmentArea, Zone}
  alias Salvorion.Organisation.Department
  alias Salvorion.Repo

  @type opts :: Salvorion.Audit.Multi.opts()

  # ---------------------------------------------------------------------------
  # Assembly points
  # ---------------------------------------------------------------------------

  @doc "Creates an assembly point. `attrs` needs `:name`; `:description`, `:latitude`, `:longitude` are optional."
  @spec create_assembly_point(map, opts) ::
          {:ok, %AssemblyPoint{}} | {:error, Ecto.Changeset.t()}
  def create_assembly_point(attrs, opts \\ []) do
    Multi.new()
    |> Multi.insert(:assembly_point, AssemblyPoint.changeset(%AssemblyPoint{}, attrs))
    |> audit(
      :assembly_point,
      "assembly_point.created",
      "assembly_point",
      nil,
      &assembly_point_snapshot/1,
      opts
    )
    |> run_audited(:assembly_point)
  end

  @spec list_assembly_points() :: [%AssemblyPoint{}]
  def list_assembly_points, do: Repo.all(from ap in AssemblyPoint, order_by: ap.name)

  @doc "Finds an assembly point by exact name, or nil. Used by the seed for idempotency."
  @spec get_assembly_point_by_name(String.t()) :: %AssemblyPoint{} | nil
  def get_assembly_point_by_name(name) when is_binary(name),
    do: Repo.get_by(AssemblyPoint, name: name)

  # ---------------------------------------------------------------------------
  # Zones
  # ---------------------------------------------------------------------------

  @doc """
  Creates a zone. `attrs` needs `:number` and `:assembly_point_id`; the
  assembly point must exist, which is checked before the insert so the
  error surfaces on the changeset rather than as a foreign-key violation.
  """
  @spec create_zone(map, opts) :: {:ok, %Zone{}} | {:error, Ecto.Changeset.t()}
  def create_zone(attrs, opts \\ []) do
    changeset =
      %Zone{}
      |> Zone.changeset(attrs)
      |> validate_exists(:assembly_point_id, AssemblyPoint)

    Multi.new()
    |> Multi.insert(:zone, changeset)
    |> audit(:zone, "zone.created", "zone", nil, &zone_snapshot/1, opts)
    |> run_audited(:zone)
  end

  @doc "Every zone ordered by `:number`, with its assembly point preloaded."
  @spec list_zones() :: [%Zone{}]
  def list_zones do
    Repo.all(from z in Zone, order_by: z.number, preload: :assembly_point)
  end

  @doc "Finds a zone by number, or nil. Used by the seed for idempotency."
  @spec get_zone_by_number(integer) :: %Zone{} | nil
  def get_zone_by_number(number) when is_integer(number), do: Repo.get_by(Zone, number: number)

  # ---------------------------------------------------------------------------
  # Areas
  # ---------------------------------------------------------------------------

  @doc """
  Creates an area. `attrs` needs `:name` and `:zone_id` (the zone must
  exist, checked before the insert); `:building` and `:floor` are optional.
  """
  @spec create_area(map, opts) :: {:ok, %Area{}} | {:error, Ecto.Changeset.t()}
  def create_area(attrs, opts \\ []) do
    changeset =
      %Area{}
      |> Area.changeset(attrs)
      |> validate_exists(:zone_id, Zone)

    Multi.new()
    |> Multi.insert(:area, changeset)
    |> audit(:area, "area.created", "area", nil, &area_snapshot/1, opts)
    |> run_audited(:area)
  end

  @spec list_areas_for_zone(binary | %Zone{}) :: [%Area{}]
  @doc "Every area, ordered by name (Task 5, Prompt 9 — the API's plain GET /api/areas)."
  @spec list_areas() :: [%Area{}]
  def list_areas, do: Repo.all(from a in Area, order_by: a.name)

  def list_areas_for_zone(%Zone{id: zone_id}), do: list_areas_for_zone(zone_id)

  def list_areas_for_zone(zone_id) when is_binary(zone_id) do
    Repo.all(from a in Area, where: a.zone_id == ^zone_id, order_by: a.name)
  end

  @doc "Finds an area by exact name within a zone, or nil. Used by the seed for idempotency."
  @spec get_area_by_name(binary, String.t()) :: %Area{} | nil
  def get_area_by_name(zone_id, name) when is_binary(zone_id) and is_binary(name) do
    Repo.get_by(Area, zone_id: zone_id, name: name)
  end

  # ---------------------------------------------------------------------------
  # Department <-> Area links (department_areas)
  # ---------------------------------------------------------------------------

  @doc """
  Links a department to an area (a row in `department_areas`). Both must
  exist and the pair must not already be linked; either failure is
  reported on the changeset.
  """
  @spec link_department_to_area(binary | %Department{}, binary | %Area{}, opts) ::
          {:ok, %DepartmentArea{}} | {:error, Ecto.Changeset.t()}
  def link_department_to_area(department, area, opts \\ [])

  def link_department_to_area(%Department{id: id}, area, opts),
    do: link_department_to_area(id, area, opts)

  def link_department_to_area(department_id, %Area{id: id}, opts),
    do: link_department_to_area(department_id, id, opts)

  def link_department_to_area(department_id, area_id, opts) do
    changeset =
      %DepartmentArea{}
      |> DepartmentArea.changeset(%{department_id: department_id, area_id: area_id})
      |> validate_exists(:department_id, Department)
      |> validate_exists(:area_id, Area)

    Multi.new()
    |> Multi.insert(:link, changeset)
    |> audit(:link, "department_area.linked", "department_area", nil, &link_snapshot/1, opts)
    |> run_audited(:link)
  end

  @doc """
  Removes the link between a department and an area. Returns
  `{:ok, department_area}` with the deleted row, or `{:error, :not_found}`
  when the pair was not linked. The deletion and its audit row (before
  snapshot, `after: nil`) are written in one transaction.
  """
  @spec unlink_department_from_area(binary | %Department{}, binary | %Area{}, opts) ::
          {:ok, %DepartmentArea{}} | {:error, :not_found}
  def unlink_department_from_area(department, area, opts \\ [])

  def unlink_department_from_area(%Department{id: id}, area, opts),
    do: unlink_department_from_area(id, area, opts)

  def unlink_department_from_area(department_id, %Area{id: id}, opts),
    do: unlink_department_from_area(department_id, id, opts)

  def unlink_department_from_area(department_id, area_id, opts) do
    case get_link(department_id, area_id) do
      nil ->
        {:error, :not_found}

      %DepartmentArea{} = link ->
        Multi.new()
        |> Multi.delete(:link, link)
        |> audit(
          :link,
          "department_area.unlinked",
          "department_area",
          link_snapshot(link),
          nil,
          opts
        )
        |> run_audited(:link)
    end
  end

  @doc "The `department_areas` row for a pair, or nil."
  @spec get_link(binary, binary) :: %DepartmentArea{} | nil
  def get_link(department_id, area_id) do
    with {:ok, d} <- Ecto.UUID.cast(department_id),
         {:ok, a} <- Ecto.UUID.cast(area_id) do
      Repo.get_by(DepartmentArea, department_id: d, area_id: a)
    else
      :error -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Hierarchy
  # ---------------------------------------------------------------------------

  @doc """
  Every assembly point with its zones (ordered by number), each zone with
  its areas (ordered by name), each area with its linked departments
  (ordered by name) preloaded. Assembly points are ordered by their lowest
  zone number so the list reads in the same order as the OSH guide; an
  assembly point with no zones yet sorts last.

  Built for the locations admin screen (Document 11, section 2.4) and
  reused by the OSH guide seed's own verification.
  """
  @spec get_assembly_point_hierarchy() :: [%AssemblyPoint{}]
  def get_assembly_point_hierarchy do
    departments = from d in Department, order_by: d.name
    areas = from a in Area, order_by: a.name, preload: [departments: ^departments]
    zones = from z in Zone, order_by: z.number, preload: [areas: ^areas]

    AssemblyPoint
    |> Repo.all()
    |> Repo.preload(zones: zones)
    |> Enum.sort_by(&first_zone_number/1)
  end

  defp first_zone_number(%AssemblyPoint{zones: []}), do: {1, nil}
  defp first_zone_number(%AssemblyPoint{zones: [z | _]}), do: {0, z.number}

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # Adds a changeset error when `field` names a row that does not exist in
  # `schema`, so a bad parent id is reported like any other validation
  # rather than as a foreign-key exception. Skipped when the field is
  # already invalid or blank (validate_required reports that).
  defp validate_exists(changeset, field, schema) do
    case Changeset.fetch_field(changeset, field) do
      {_, id} when is_binary(id) ->
        with {:ok, uuid} <- Ecto.UUID.cast(id),
             true <- Repo.exists?(from r in schema, where: r.id == ^uuid) do
          changeset
        else
          _ -> Changeset.add_error(changeset, field, "does not exist")
        end

      _ ->
        changeset
    end
  end

  # ---------------------------------------------------------------------------
  # Audit snapshots (what lands in audit_logs.before/after)
  # ---------------------------------------------------------------------------

  defp assembly_point_snapshot(%AssemblyPoint{} = ap),
    do: %{
      id: ap.id,
      name: ap.name,
      description: ap.description,
      latitude: ap.latitude,
      longitude: ap.longitude
    }

  defp zone_snapshot(%Zone{} = z),
    do: %{id: z.id, number: z.number, assembly_point_id: z.assembly_point_id}

  defp area_snapshot(%Area{} = a),
    do: %{id: a.id, name: a.name, building: a.building, floor: a.floor, zone_id: a.zone_id}

  defp link_snapshot(%DepartmentArea{} = l),
    do: %{id: l.id, department_id: l.department_id, area_id: l.area_id}
end
