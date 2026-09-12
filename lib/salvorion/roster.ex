defmodule Salvorion.Roster do
  @moduledoc """
  The Roster context: the people who may be on campus (staff, students,
  visitors), their secondary departmental memberships, and the history of
  roster import runs (FR-ROS-01 to FR-ROS-04; Technical Foundation 03,
  section 2.2).

  Staff and students arrive through a `Salvorion.Roster.Provider`
  implementation (see `Salvorion.Roster.Importer`) and are matched on
  `id_number` via `upsert_person_by_id_number/2`. Visitors have no ID
  number and are always created fresh at registration (a later prompt).

  Every create/update takes an `opts` keyword list whose `:actor` names
  the authenticated user performing the action; the change and its audit
  row are written in one transaction via `Salvorion.Audit.Multi`, the same
  convention as `Salvorion.Accounts`, `Salvorion.Organisation` and
  `Salvorion.Locations`. Pass no actor only where there is genuinely no
  acting user (an import run from a mix task or a scheduled job).
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [audit: 7, run_audited: 2]

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Salvorion.Organisation.Department
  alias Salvorion.Repo
  alias Salvorion.Roster.{Person, PersonDepartment, RosterImport}

  @type opts :: Salvorion.Audit.Multi.opts()

  # ---------------------------------------------------------------------------
  # People
  # ---------------------------------------------------------------------------

  @doc """
  Creates a person. `attrs` needs `:type`, `:first_name`, `:last_name`,
  `:source`, and `:id_number` unless the type is `"visitor"`. Referenced
  department, programme and area ids must exist; a bad id is reported on
  the changeset rather than as a foreign-key exception.
  """
  @spec create_person(map, opts) :: {:ok, %Person{}} | {:error, Ecto.Changeset.t()}
  def create_person(attrs, opts \\ []) do
    Multi.new()
    |> Multi.insert(:person, person_changeset(%Person{}, attrs))
    |> audit(:person, "person.created", "person", nil, &person_snapshot/1, opts)
    |> run_audited(:person)
  end

  @spec update_person(%Person{}, map, opts) :: {:ok, %Person{}} | {:error, Ecto.Changeset.t()}
  def update_person(%Person{} = person, attrs, opts \\ []) do
    before = person_snapshot(person)

    Multi.new()
    |> Multi.update(:person, person_changeset(person, attrs))
    |> audit(:person, "person.updated", "person", before, &person_snapshot/1, opts)
    |> run_audited(:person)
  end

  @spec get_person!(binary) :: %Person{}
  def get_person!(id), do: Repo.get!(Person, id)

  @doc """
  The person carrying `id_number`, or nil. This is the lookup behind an ID
  card scan (FR-SIGN-01): a number that matches nobody is an expected
  outcome during scanning, not an error, so it never raises.
  """
  @spec get_person_by_id_number(String.t() | nil) :: %Person{} | nil
  def get_person_by_id_number(id_number) when is_binary(id_number) do
    case String.trim(id_number) do
      "" -> nil
      trimmed -> Repo.get_by(Person, id_number: trimmed)
    end
  end

  def get_person_by_id_number(_), do: nil

  @doc """
  Case-insensitive partial match on first and/or last name, for the
  manual name-search flow (FR-SIGN-03). The query is split on whitespace
  and every term must match either name, so `"mar quil"` finds
  "Marlow Quillbrook" as well as `"quillbrook"` alone. A blank query
  returns no one. Results are ordered by last name, then first name, and
  capped at `:limit` (default 50).
  """
  @spec search_people_by_name(String.t(), limit: pos_integer) :: [%Person{}]
  def search_people_by_name(query, opts \\ [])

  def search_people_by_name(query, opts) when is_binary(query) do
    case String.split(query) do
      [] ->
        []

      terms ->
        terms
        |> Enum.reduce(Person, fn term, q ->
          pattern = "%" <> escape_like(term) <> "%"

          where(
            q,
            [p],
            ilike(p.first_name, ^pattern) or ilike(p.last_name, ^pattern)
          )
        end)
        |> order_by([p], asc: p.last_name, asc: p.first_name)
        |> limit(^Keyword.get(opts, :limit, 50))
        |> Repo.all()
    end
  end

  def search_people_by_name(_, _), do: []

  @doc """
  Lists people, ordered by last name then first name.

  Filters (all optional, as a keyword list or map):

    * `:type`          - `"staff"`, `"student"` or `"visitor"`
    * `:department_id` - people whose `primary_department_id` is this
      department OR who hold a secondary membership in it through
      `person_departments`
    * `:source`        - `"roster"`, `"synthetic"` or `"visitor_registration"`
    * `:limit`         - defaults to no limit
  """
  @spec list_people(keyword | map) :: [%Person{}]
  def list_people(filters \\ []) do
    filters = Map.new(filters)

    Person
    |> filter_eq(:type, filters[:type])
    |> filter_eq(:source, filters[:source])
    |> filter_department(filters[:department_id])
    |> order_by([p], asc: p.last_name, asc: p.first_name)
    |> maybe_limit(filters[:limit])
    |> Repo.all()
  end

  @doc """
  Creates the person identified by `attrs.id_number` if none exists, or
  updates the existing one; this is how every roster provider writes
  staff and students. The audit row records `person.created` or
  `person.updated` accordingly. Returns `{:error, changeset}` when
  `id_number` is blank, since there is nothing to match on.
  """
  @spec upsert_person_by_id_number(map, opts) ::
          {:ok, %Person{}} | {:error, Ecto.Changeset.t()}
  def upsert_person_by_id_number(attrs, opts \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    id_number = attrs["id_number"]

    case get_person_by_id_number(id_number) do
      nil -> create_person(attrs, opts)
      %Person{} = person -> update_person(person, attrs, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # Secondary departmental membership (person_departments)
  # ---------------------------------------------------------------------------

  @doc """
  Registers a secondary departmental membership (a row in
  `person_departments`). Both person and department must exist and the
  pair must not already be registered; either failure is reported on the
  changeset. Mirrors `Salvorion.Locations.link_department_to_area/3`.
  """
  @spec register_person_department(binary | %Person{}, binary | %Department{}, opts) ::
          {:ok, %PersonDepartment{}} | {:error, Ecto.Changeset.t()}
  def register_person_department(person, department, opts \\ [])

  def register_person_department(%Person{id: id}, department, opts),
    do: register_person_department(id, department, opts)

  def register_person_department(person_id, %Department{id: id}, opts),
    do: register_person_department(person_id, id, opts)

  def register_person_department(person_id, department_id, opts) do
    changeset =
      %PersonDepartment{}
      |> PersonDepartment.changeset(%{person_id: person_id, department_id: department_id})
      |> validate_exists(:person_id, Person)
      |> validate_exists(:department_id, Department)

    Multi.new()
    |> Multi.insert(:membership, changeset)
    |> audit(
      :membership,
      "person_department.registered",
      "person_department",
      nil,
      &membership_snapshot/1,
      opts
    )
    |> run_audited(:membership)
  end

  @doc """
  Removes a secondary departmental membership. Returns `{:ok, membership}`
  with the deleted row, or `{:error, :not_found}` when the pair was not
  registered. The deletion and its audit row (before snapshot,
  `after: nil`) are written in one transaction.
  """
  @spec remove_person_department(binary | %Person{}, binary | %Department{}, opts) ::
          {:ok, %PersonDepartment{}} | {:error, :not_found}
  def remove_person_department(person, department, opts \\ [])

  def remove_person_department(%Person{id: id}, department, opts),
    do: remove_person_department(id, department, opts)

  def remove_person_department(person_id, %Department{id: id}, opts),
    do: remove_person_department(person_id, id, opts)

  def remove_person_department(person_id, department_id, opts) do
    case get_person_department(person_id, department_id) do
      nil ->
        {:error, :not_found}

      %PersonDepartment{} = membership ->
        Multi.new()
        |> Multi.delete(:membership, membership)
        |> audit(
          :membership,
          "person_department.removed",
          "person_department",
          membership_snapshot(membership),
          nil,
          opts
        )
        |> run_audited(:membership)
    end
  end

  @doc "The `person_departments` row for a pair, or nil."
  @spec get_person_department(binary, binary) :: %PersonDepartment{} | nil
  def get_person_department(person_id, department_id) do
    with {:ok, p} <- Ecto.UUID.cast(person_id),
         {:ok, d} <- Ecto.UUID.cast(department_id) do
      Repo.get_by(PersonDepartment, person_id: p, department_id: d)
    else
      :error -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Roster imports
  # ---------------------------------------------------------------------------

  @doc """
  Opens a `RosterImport` row for `provider` (`"file_import"`,
  `"scheduled_export"`, `"direct_database"` or `"synthetic"`) with
  `started_at` set to now. The run is in progress while `completed_at`
  is nil; there is no separate status column.
  """
  @spec start_roster_import(String.t(), opts) ::
          {:ok, %RosterImport{}} | {:error, Ecto.Changeset.t()}
  def start_roster_import(provider, opts \\ []) do
    changeset =
      RosterImport.changeset(%RosterImport{}, %{
        provider: provider,
        started_at: DateTime.utc_now()
      })

    Multi.new()
    |> Multi.insert(:import, changeset)
    |> audit(:import, "roster_import.started", "roster_import", nil, &import_snapshot/1, opts)
    |> run_audited(:import)
  end

  @doc """
  Closes an import run: sets `completed_at`, `total_records`,
  `error_count` (the length of `errors`) and stores the row-level errors
  as `%{"rows" => [%{"row" => n, "reason" => "..."}]}`. `errors` is the
  list every provider returns, `[%{row: n, reason: "..."}]`.
  """
  @spec complete_roster_import(%RosterImport{}, non_neg_integer, [map], opts) ::
          {:ok, %RosterImport{}} | {:error, Ecto.Changeset.t()}
  def complete_roster_import(%RosterImport{} = import, total_records, errors, opts \\ [])
      when is_integer(total_records) and is_list(errors) do
    before = import_snapshot(import)

    changeset =
      RosterImport.changeset(import, %{
        completed_at: DateTime.utc_now(),
        total_records: total_records,
        error_count: length(errors),
        errors: %{"rows" => Enum.map(errors, &error_entry/1)}
      })

    Multi.new()
    |> Multi.update(:import, changeset)
    |> audit(
      :import,
      "roster_import.completed",
      "roster_import",
      before,
      &import_snapshot/1,
      opts
    )
    |> run_audited(:import)
  end

  @doc "Every import run, most recent first, for the admin history screen (Document 11, section 2.6)."
  @spec list_roster_imports() :: [%RosterImport{}]
  def list_roster_imports do
    Repo.all(from i in RosterImport, order_by: [desc: i.started_at, desc: i.id])
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp person_changeset(person, attrs) do
    person
    |> Person.changeset(attrs)
    |> validate_exists(:primary_department_id, Department)
    |> validate_exists(:programme_id, Salvorion.Organisation.Programme)
    |> validate_exists(:usual_area_id, Salvorion.Locations.Area)
  end

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, field, value), do: where(query, [p], field(p, ^field) == ^value)

  defp filter_department(query, nil), do: query

  defp filter_department(query, department_id) do
    secondary =
      from pd in PersonDepartment,
        where: pd.department_id == ^department_id,
        select: pd.person_id

    where(
      query,
      [p],
      p.primary_department_id == ^department_id or p.id in subquery(secondary)
    )
  end

  defp maybe_limit(query, nil), do: query
  defp maybe_limit(query, n), do: limit(query, ^n)

  # ILIKE treats %, _ and \ specially; a search for "100%" must not match everything.
  defp escape_like(term), do: Regex.replace(~r/[\\%_]/, term, "\\\\\\0")

  # Adds a changeset error when `field` names a row that does not exist in
  # `schema`, so a bad parent id is reported like any other validation
  # rather than as a foreign-key exception. Skipped when the field is
  # already invalid or blank.
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

  defp error_entry(%{row: row, reason: reason}), do: %{"row" => row, "reason" => reason}
  defp error_entry(%{"row" => _, "reason" => _} = entry), do: entry

  # ---------------------------------------------------------------------------
  # Audit snapshots (what lands in audit_logs.before/after)
  # ---------------------------------------------------------------------------

  defp person_snapshot(%Person{} = p),
    do: %{
      id: p.id,
      type: p.type,
      id_number: p.id_number,
      first_name: p.first_name,
      last_name: p.last_name,
      email: p.email,
      phone: p.phone,
      primary_department_id: p.primary_department_id,
      programme_id: p.programme_id,
      usual_area_id: p.usual_area_id,
      source: p.source,
      visitor_host: p.visitor_host,
      visitor_expires_at: p.visitor_expires_at
    }

  defp membership_snapshot(%PersonDepartment{} = m),
    do: %{id: m.id, person_id: m.person_id, department_id: m.department_id}

  defp import_snapshot(%RosterImport{} = i),
    do: %{
      id: i.id,
      provider: i.provider,
      started_at: i.started_at,
      completed_at: i.completed_at,
      total_records: i.total_records,
      error_count: i.error_count
    }
end
