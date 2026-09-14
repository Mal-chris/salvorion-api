defmodule Salvorion.Roster do
  @moduledoc """
  The Roster context: the people who may be on campus (staff, students,
  visitors), their secondary departmental memberships, and the history of
  roster import runs (FR-ROS-01 to FR-ROS-04; Technical Foundation 03,
  section 2.2).

  Staff and students arrive through a `Salvorion.Roster.Provider`
  implementation (see `Salvorion.Roster.Importer`) and are matched on
  `id_number` via `upsert_person_by_id_number/2`. Visitors are always
  created fresh at registration (`register_visitor/2`), with a generated
  pass code standing in for `id_number` (FR-VIS-01/02; docs/DECISIONS.md).

  Every create/update takes an `opts` keyword list whose `:actor` names
  the authenticated user performing the action; the change and its audit
  row are written in one transaction via `Salvorion.Audit.Multi`, the same
  convention as `Salvorion.Accounts`, `Salvorion.Organisation` and
  `Salvorion.Locations`. Pass no actor only where there is genuinely no
  acting user (an import run from a mix task or a scheduled job).
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [audit: 7, run_audited: 2, actor_id: 1]

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Salvorion.Accountability
  alias Salvorion.Audit
  alias Salvorion.Organisation.Department
  alias Salvorion.Repo
  alias Salvorion.Roster.{Person, PersonDepartment, RosterImport}
  alias Salvorion.Settings

  @type opts :: Salvorion.Audit.Multi.opts()

  # Crockford base32: no I, L, O, U (visually confusable with 1, 1, 0, V).
  @pass_code_alphabet ~c"0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @pass_code_attempts 5

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
    * `:limit`         - page size, defaults to no limit
    * `:offset`        - defaults to 0; used with `:limit` for pagination
      (the one list here large enough to need it — Task 1, Prompt 9)
  """
  @spec list_people(keyword | map) :: [%Person{}]
  def list_people(filters \\ []) do
    filters
    |> Map.new()
    |> people_query()
    |> order_by([p], asc: p.last_name, asc: p.first_name)
    |> maybe_limit(filters[:limit])
    |> maybe_offset(filters[:offset])
    |> Repo.all()
  end

  @doc "The total count of people matching `list_people/1`'s filters, ignoring `:limit`/`:offset`, for pagination metadata."
  @spec count_people(keyword | map) :: non_neg_integer
  def count_people(filters \\ []) do
    filters
    |> Map.new()
    |> people_query()
    |> Repo.aggregate(:count)
  end

  defp people_query(filters) do
    Person
    |> filter_eq(:type, filters[:type])
    |> filter_eq(:source, filters[:source])
    |> filter_department(filters[:department_id])
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
  # Visitors (FR-VIS-01 to FR-VIS-04; docs/DECISIONS.md)
  # ---------------------------------------------------------------------------

  @doc """
  Registers a visitor (FR-VIS-01): a `Person` with `type: "visitor"`,
  `source: "visitor_registration"`, and `id_number` set to a generated
  pass code, `"VIS-"` followed by 8 Crockford-base32 characters
  (`:crypto.strong_rand_bytes/1`; retried on the astronomically unlikely
  unique-index collision — docs/DECISIONS.md). This pass code is what
  the client renders as the visitor's temporary QR pass (FR-VIS-02): a
  scan of it resolves through `get_person_by_id_number/1` exactly like
  a staff or student card, no special visitor path.

  `attrs` needs `:first_name`, `:last_name`, `:visitor_host`; optional
  `:phone`, `:email`, `:visitor_expires_at` (a `Date`, defaults to
  today). `opts` takes the usual `:actor` plus, when registration
  happens at an assembly point during an activation (docs/09, section
  2): `:activation_id`, `:assembly_point_id`, `:area_id`, `:device_id`,
  `:recorded_by_id` (defaults to `:actor`), and optionally `:client_uuid`
  / `:client_timestamp` for an offline client replaying a queued
  registration.

  Returns `{:ok, person, event}` when `:activation_id` is given and the
  event was ingested, `{:ok, person, nil}` when it was not given, or
  `{:ok, person, {:error, reason}}` when it was given but ingestion
  failed (e.g. the activation has since closed) — the person is created
  either way; a failed sign-in event is not a reason to undo the
  registration, since the person is still standing there and the warden
  still needs a record of them and a pass to hand over. Returns
  `{:error, changeset}` only when the person itself could not be
  created.
  """
  @spec register_visitor(map, opts) ::
          {:ok, %Person{}, %Accountability.AccountabilityEvent{} | nil | {:error, term}}
          | {:error, Ecto.Changeset.t()}
  def register_visitor(attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put("type", "visitor")
      |> Map.put("source", "visitor_registration")
      |> Map.put_new("visitor_expires_at", Date.utc_today())

    case create_visitor_with_pass_code(attrs, opts, @pass_code_attempts) do
      {:ok, person} -> {:ok, person, maybe_ingest_visitor_sign_in(person, opts)}
      {:error, _} = error -> error
    end
  end

  defp create_visitor_with_pass_code(_attrs, _opts, 0) do
    {:error, :pass_code_generation_failed}
  end

  defp create_visitor_with_pass_code(attrs, opts, attempts_left) do
    changeset =
      %Person{}
      |> person_changeset(Map.put(attrs, "id_number", generate_pass_code()))
      |> visitor_host_required()

    Multi.new()
    |> Multi.insert(:person, changeset)
    |> audit(:person, "visitor.registered", "person", nil, &visitor_snapshot/1, opts)
    |> run_audited(:person)
    |> case do
      {:ok, person} ->
        {:ok, person}

      {:error, %Changeset{errors: errors} = changeset} ->
        if Keyword.has_key?(errors, :id_number) do
          create_visitor_with_pass_code(attrs, opts, attempts_left - 1)
        else
          {:error, changeset}
        end
    end
  end

  defp visitor_host_required(changeset),
    do: Changeset.validate_required(changeset, [:visitor_host])

  defp generate_pass_code do
    code =
      8
      |> :crypto.strong_rand_bytes()
      |> :binary.bin_to_list()
      |> Enum.map(&Enum.at(@pass_code_alphabet, rem(&1, 32)))
      |> List.to_string()

    "VIS-" <> code
  end

  # Runs only after register_visitor/2's own transaction (above) has
  # committed: ingest_event/2 manages its own transaction and must not be
  # called inside an enclosing one (Prompt 7 follow-up). A missing
  # :activation_id means this registration was not at an assembly point
  # during an activation (e.g. advance registration at reception).
  defp maybe_ingest_visitor_sign_in(%Person{} = person, opts) do
    case Keyword.get(opts, :activation_id) do
      nil ->
        nil

      activation_id ->
        recorded_by_id = Keyword.get(opts, :recorded_by_id) || actor_id(opts)

        attrs = %{
          client_uuid: Keyword.get_lazy(opts, :client_uuid, &Ecto.UUID.generate/0),
          activation_id: activation_id,
          person_id: person.id,
          kind: "visitor_registered",
          status: "present",
          recorded_by_id: recorded_by_id,
          device_id: Keyword.get(opts, :device_id),
          assembly_point_id: Keyword.get(opts, :assembly_point_id),
          area_id: Keyword.get(opts, :area_id),
          client_timestamp: Keyword.get_lazy(opts, :client_timestamp, &DateTime.utc_now/0)
        }

        case Accountability.ingest_event(attrs, actor: recorded_by_id) do
          {:ok, event, _person_status_or_duplicate} -> event
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  What the client shows on the visitor's pass screen (Document 11,
  section 1.4): the pass code (rendered as a QR), name, host and
  expiry.
  """
  @spec visitor_pass(%Person{}) :: map
  def visitor_pass(%Person{type: "visitor"} = person) do
    %{
      pass_code: person.id_number,
      first_name: person.first_name,
      last_name: person.last_name,
      visitor_host: person.visitor_host,
      visitor_expires_at: person.visitor_expires_at
    }
  end

  @doc """
  Visitors active on `opts[:active_on]` (default today) —
  `visitor_expires_at >= that date` — newest first.
  """
  @spec list_visitors(keyword | map) :: [%Person{}]
  def list_visitors(opts \\ []) do
    opts = Map.new(opts)
    active_on = Map.get(opts, :active_on, Date.utc_today())

    Repo.all(
      from p in Person,
        where: p.type == "visitor" and p.visitor_expires_at >= ^active_on,
        order_by: [desc: p.inserted_at]
    )
  end

  @doc """
  Anonymises visitors whose retention period has elapsed (FR-VIS-04;
  NFR-PRIV-01): `visitor_expires_at + Setting("visitor_retention_days",
  90) < today`. Sets `first_name`/`last_name` to a fixed placeholder and
  clears `email`, `phone`, `visitor_host` in one `UPDATE ... WHERE` (not
  one changeset write per row); already-purged rows are excluded so
  re-running is a no-op. `id_number` (the pass code) and the row itself
  are kept: it carries no personal information and preserves the link
  from `AccountabilityEvent`/`PersonStatus` history to a resolvable
  person (accountability history is retained indefinitely, only
  personal details are purged). One audit row for the whole run —
  never one per visitor, which would re-record who they were — actor
  `nil` by default: this is a system action (an Oban job, Task 4), not
  something a user did.
  """
  @spec purge_expired_visitors(opts) :: {:ok, non_neg_integer}
  def purge_expired_visitors(opts \\ []) do
    retention_days = Settings.get_setting("visitor_retention_days", 90)
    cutoff = Date.add(Date.utc_today(), -retention_days)

    Repo.transaction(fn ->
      {count, _} =
        Repo.update_all(
          from(p in Person,
            where: p.type == "visitor",
            where: not is_nil(p.visitor_expires_at) and p.visitor_expires_at < ^cutoff,
            where: not (p.first_name == "Visitor" and p.last_name == "(purged)")
          ),
          set: [
            first_name: "Visitor",
            last_name: "(purged)",
            email: nil,
            phone: nil,
            visitor_host: nil,
            updated_at: DateTime.utc_now()
          ]
        )

      {:ok, _} =
        Audit.record(%{
          actor_user_id: actor_id(opts),
          action: "visitor.purged",
          entity_type: "visitor_purge",
          entity_id: nil,
          after: %{count: count, retention_days: retention_days, cutoff: cutoff}
        })

      count
    end)
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

  defp maybe_offset(query, nil), do: query
  defp maybe_offset(query, n), do: offset(query, ^n)

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

  # Deliberately NOT person_snapshot/1: that includes name, phone, email
  # and host, which would sit in audit_logs.after forever, immune to
  # purge_expired_visitors/1 (which only ever touches the people table —
  # docs/DECISIONS.md, "the visitor-registration audit row kept personal
  # data purge_expired_visitors/1 never reached"). person_id and the pass
  # code are enough to find the (by-then-anonymised) person row and the
  # events keyed off them if this action is ever audited-for; nothing
  # here is itself personal data.
  defp visitor_snapshot(%Person{} = p),
    do: %{
      person_id: p.id,
      pass_code: p.id_number,
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
