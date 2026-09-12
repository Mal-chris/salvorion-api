defmodule Salvorion.Activations do
  @moduledoc """
  The Activations context: the lifecycle of a drill or real emergency,
  from scheduling through to being reported (FR-ACT-01 to FR-ACT-06; the
  state diagram in Document 08, section 5):

      scheduled -> active -> closed -> reported

  `schedule_activation/2` and `start_activation/2` both accept `attrs`
  with an optional `"zone_ids"` list, used only when `scope == "zones"`;
  the `Activation` and `ActivationZone` schemas and their four
  changesets (in `Salvorion.Activations.Activation`) are not modified
  here, only wrapped.

  Every lifecycle function takes an `opts` keyword list whose `:actor`
  names the authenticated user performing the action, same convention as
  `Salvorion.Accounts`, `Salvorion.Organisation`, `Salvorion.Locations`
  and `Salvorion.Roster`. Unlike those contexts, `:actor` is not merely
  recorded on the audit row here: scheduling and starting an activation
  populate the schema's own `started_by_id` from it, so omitting it is a
  validation error ("can't be blank"), not a silently-nil audit actor
  these are always user-initiated (FR-ACT-06). `close_activation/2`
  works the same way for `closed_by_id`. `mark_activation_reported/1` is
  the exception: it is invoked by the Reporting context once a report
  run completes, not directly by a user, so it takes no `opts` and
  audits with no actor.

  ## The zone-overlap guard (FR-ACT-05)

  "No two active activations may overlap in the same zone" cannot be a
  database constraint: campus-wide activations have no rows in
  `activation_zones`, so no partial unique index can express the rule.
  It is instead enforced inside the transaction that makes an activation
  active, guarded by a Postgres advisory lock
  (`pg_advisory_xact_lock/1`, keyed by `@start_lock_key`, released
  automatically at transaction end) that serialises every attempt to
  start an activation against every other one. This is a deliberate
  bottleneck: starting an activation is a rare, human-initiated action,
  not a hot path, so trading throughput for a race-free check is the
  right trade. Once the lock is held:

    * a new **campus**-scope activation conflicts with *any* other
      currently active activation, regardless of that other one's scope;
    * a new **zones**-scope activation conflicts with an active
      **campus**-scope activation (which implicitly covers every zone),
      or with an active **zones**-scope activation sharing at least one
      zone.

  A conflict is returned as `{:error, {:zone_conflict, message}}`, the
  message naming the id and scope of every activation it conflicts with.
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [audit: 7, run_audited: 2, actor_id: 1]

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Salvorion.Accountability
  alias Salvorion.Activations.{Activation, ActivationZone}
  alias Salvorion.Locations.Zone
  alias Salvorion.Repo

  @type opts :: Salvorion.Audit.Multi.opts()

  # Fixed key for the advisory lock taken while starting an activation.
  # Arbitrary but constant: every start attempt, for any activation,
  # takes the same lock, which is what serialises them against each other.
  @start_lock_key 891_001

  @pubsub Salvorion.PubSub

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  @doc """
  Schedules an activation in advance (`schedule_changeset/2`); it stays
  `"scheduled"` until `start_activation/2` is called on it. `attrs` needs
  `:activation_type`, `:started_at` (the planned start time) and,
  when `scope` is `"zones"` (the default is `"campus"`), a `:zone_ids`
  list, every id validated to exist. `:started_by_id` is not accepted in
  `attrs`; it comes from `opts[:actor]`.
  """
  @spec schedule_activation(map, opts) :: {:ok, %Activation{}} | {:error, Ecto.Changeset.t()}
  def schedule_activation(attrs, opts \\ []) do
    attrs = normalize_attrs(attrs, opts)
    zone_ids = extract_zone_ids(attrs)
    changeset = Activation.schedule_changeset(%Activation{}, attrs)

    Multi.new()
    |> Multi.run(:zone_ids, fn repo, _ -> finalize_zone_ids(repo, changeset, zone_ids) end)
    |> Multi.insert(:activation, fn %{zone_ids: {cs, _ids}} -> cs end)
    |> Multi.run(:zones, fn repo, %{activation: activation, zone_ids: {_cs, ids}} ->
      insert_activation_zones(repo, activation, ids)
    end)
    |> audit(:activation, "activation.scheduled", "activation", nil, &activation_snapshot/1, opts)
    |> run_audited(:activation)
  end

  @doc """
  Starts an activation. Given `attrs` (a map), creates and activates it
  directly in one step (`start_changeset/2`) — the common case, since
  most drills and all real emergencies start immediately with no
  scheduling step. Given an existing `%Activation{status: "scheduled"}`,
  transitions it to `"active"` instead, refreshing `started_at` to now
  and reusing the zones it was scheduled against.

  Either path takes the advisory lock and runs the zone-overlap check
  described in the module doc before the activation becomes active, and
  may return `{:error, {:zone_conflict, message}}`.
  """
  @spec start_activation(map, opts) :: start_result
  @spec start_activation(%Activation{}, opts) :: start_result
  @type start_result ::
          {:ok, %Activation{}}
          | {:error,
             Ecto.Changeset.t() | {:zone_conflict, String.t()} | {:invalid_state, String.t()}}
  def start_activation(attrs_or_activation, opts \\ [])

  def start_activation(attrs, opts) when is_map(attrs) and not is_struct(attrs) do
    attrs = normalize_attrs(attrs, opts)
    zone_ids = extract_zone_ids(attrs)
    changeset = Activation.start_changeset(%Activation{}, attrs)

    Multi.new()
    |> Multi.run(:zone_ids, fn repo, _ -> finalize_zone_ids(repo, changeset, zone_ids) end)
    |> Multi.run(:lock, fn repo, _ -> acquire_start_lock(repo) end)
    |> Multi.run(:conflict, fn repo, %{zone_ids: {cs, ids}} ->
      check_overlap(repo, Changeset.get_field(cs, :scope), ids)
    end)
    |> Multi.insert(:activation, fn %{zone_ids: {cs, _ids}} -> cs end)
    |> Multi.run(:zones, fn repo, %{activation: activation, zone_ids: {_cs, ids}} ->
      insert_activation_zones(repo, activation, ids)
    end)
    |> Multi.run(:expectations, fn _repo, %{activation: activation} ->
      Accountability.initialise_for_activation(activation)
    end)
    |> audit(:activation, "activation.started", "activation", nil, &activation_snapshot/1, opts)
    |> run_audited(:activation)
    |> broadcast_activation_changed()
  end

  def start_activation(%Activation{status: "scheduled"} = activation, opts) do
    before = activation_snapshot(activation)

    Multi.new()
    |> Multi.run(:zone_ids, fn repo, _ -> {:ok, zone_ids_for_activation(repo, activation.id)} end)
    |> Multi.run(:lock, fn repo, _ -> acquire_start_lock(repo) end)
    |> Multi.run(:conflict, fn repo, %{zone_ids: ids} ->
      check_overlap(repo, activation.scope, ids)
    end)
    |> Multi.update(:activation, fn _changes ->
      Activation.start_changeset(activation, %{
        "activation_type" => activation.activation_type,
        "scope" => activation.scope,
        "started_by_id" => activation.started_by_id,
        "started_at" => DateTime.utc_now()
      })
    end)
    |> Multi.run(:expectations, fn _repo, %{activation: activation} ->
      Accountability.initialise_for_activation(activation)
    end)
    |> audit(
      :activation,
      "activation.started",
      "activation",
      before,
      &activation_snapshot/1,
      opts
    )
    |> run_audited(:activation)
    |> broadcast_activation_changed()
  end

  def start_activation(%Activation{status: status}, _opts) do
    {:error,
     {:invalid_state, "activation must be scheduled to start this way; status is #{status}"}}
  end

  @doc """
  Closes an active activation (`close_changeset/2`), stopping new
  accountability events for it and marking it ready for report
  generation. `closed_by_id` comes from `opts[:actor]`, required, and
  `closed_at` defaults to now (override with `opts[:closed_at]`).
  Rejected with a changeset error, not a silent no-op, when `activation`
  is not currently `"active"`.
  """
  @spec close_activation(%Activation{}, opts) ::
          {:ok, %Activation{}} | {:error, Ecto.Changeset.t()}
  def close_activation(%Activation{} = activation, opts \\ []) do
    before = activation_snapshot(activation)

    attrs = %{
      closed_by_id: actor_id(opts),
      closed_at: Keyword.get(opts, :closed_at, DateTime.utc_now())
    }

    Multi.new()
    |> Multi.update(:activation, Activation.close_changeset(activation, attrs))
    |> audit(:activation, "activation.closed", "activation", before, &activation_snapshot/1, opts)
    |> run_audited(:activation)
    |> broadcast_activation_changed()
  end

  @doc """
  Transitions a closed activation to `"reported"` (`mark_reported_changeset/1`),
  called by the Reporting context once its report run has completed and
  deliveries were attempted. Takes no `opts`: this is a system-initiated
  step, not a direct user action, so its audit row has no actor.
  """
  @spec mark_activation_reported(%Activation{}) ::
          {:ok, %Activation{}} | {:error, Ecto.Changeset.t()}
  def mark_activation_reported(%Activation{} = activation) do
    before = activation_snapshot(activation)

    Multi.new()
    |> Multi.update(:activation, Activation.mark_reported_changeset(activation))
    |> audit(:activation, "activation.reported", "activation", before, &activation_snapshot/1, [])
    |> run_audited(:activation)
    |> broadcast_activation_changed()
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @spec get_activation!(binary) :: %Activation{}
  def get_activation!(id), do: Repo.get!(Activation, id)

  @doc """
  Lists activations, most recently started first.

  Filters (all optional, as a keyword list or map):

    * `:status`          - `"scheduled"`, `"active"`, `"closed"` or `"reported"`
    * `:activation_type` - `"drill"` or `"real"`
  """
  @spec list_activations(keyword | map) :: [%Activation{}]
  def list_activations(filters \\ []) do
    filters = Map.new(filters)

    Activation
    |> filter_eq(:status, filters[:status])
    |> filter_eq(:activation_type, filters[:activation_type])
    |> order_by([a], desc: a.started_at, desc: a.id)
    |> Repo.all()
  end

  @doc """
  The activation currently active over `zone_id`, whether it covers that
  zone directly (a zones-scope activation including it) or campus-wide,
  or `nil` if none. FR-ACT-05 guarantees there is at most one.
  """
  @spec get_active_activation_for_zone(binary) :: %Activation{} | nil
  def get_active_activation_for_zone(zone_id) do
    zone_scoped =
      from az in ActivationZone, where: az.zone_id == ^zone_id, select: az.activation_id

    Activation
    |> where([a], a.status == "active")
    |> where([a], a.scope == "campus" or a.id in subquery(zone_scoped))
    |> limit(1)
    |> Repo.one()
  end

  # ---------------------------------------------------------------------------
  # Broadcast (FR-DASH-05 groundwork)
  # ---------------------------------------------------------------------------

  # Strictly after run_audited/2's transaction has committed — never from
  # inside it — so a subscriber can never observe a message for a start,
  # close or report that then rolls back. Subscribe via
  # Salvorion.Accountability.subscribe/1 (same topic, one place it's public).
  defp broadcast_activation_changed({:ok, %Activation{} = activation} = result) do
    Phoenix.PubSub.broadcast(
      @pubsub,
      "activation:#{activation.id}",
      {:activation_changed, %{activation_id: activation.id, status: activation.status}}
    )

    result
  end

  defp broadcast_activation_changed(other), do: other

  # ---------------------------------------------------------------------------
  # Zone-overlap guard (FR-ACT-05)
  # ---------------------------------------------------------------------------

  defp acquire_start_lock(repo) do
    repo.query!("SELECT pg_advisory_xact_lock($1)", [@start_lock_key])
    {:ok, :locked}
  end

  defp check_overlap(repo, "campus", _zone_ids) do
    case repo.all(from a in Activation, where: a.status == "active") do
      [] -> {:ok, :no_conflict}
      conflicts -> {:error, {:zone_conflict, conflict_message(conflicts)}}
    end
  end

  defp check_overlap(_repo, "zones", []), do: {:ok, :no_conflict}

  defp check_overlap(repo, "zones", zone_ids) do
    campus_conflicts =
      repo.all(from a in Activation, where: a.status == "active" and a.scope == "campus")

    zone_conflicts =
      repo.all(
        from a in Activation,
          join: az in ActivationZone,
          on: az.activation_id == a.id,
          where: a.status == "active" and a.scope == "zones" and az.zone_id in ^zone_ids,
          distinct: true
      )

    case Enum.uniq_by(campus_conflicts ++ zone_conflicts, & &1.id) do
      [] -> {:ok, :no_conflict}
      conflicts -> {:error, {:zone_conflict, conflict_message(conflicts)}}
    end
  end

  defp conflict_message(conflicts) do
    names = Enum.map_join(conflicts, ", ", &"#{&1.id} (scope: #{&1.scope})")
    "conflicts with currently active activation(s): " <> names
  end

  # ---------------------------------------------------------------------------
  # Zone-id validation (used by both schedule_activation/2 and start_activation/2)
  # ---------------------------------------------------------------------------

  # Validates `zone_ids` against `changeset`'s scope and, once the
  # changeset is otherwise valid, that every id actually exists — a bad
  # id must be a validation error, never an orphaned activation_zones row.
  defp finalize_zone_ids(_repo, %Changeset{valid?: false} = changeset, zone_ids) do
    {:error, add_zone_ids_presence_error(changeset, zone_ids)}
  end

  defp finalize_zone_ids(repo, changeset, zone_ids) do
    changeset = add_zone_ids_presence_error(changeset, zone_ids)

    cond do
      not changeset.valid? ->
        {:error, changeset}

      Changeset.get_field(changeset, :scope) != "zones" ->
        {:ok, {changeset, []}}

      true ->
        unique_ids = Enum.uniq(zone_ids)
        found_ids = existing_zone_ids(repo, unique_ids)

        case unique_ids -- found_ids do
          [] ->
            {:ok, {changeset, unique_ids}}

          missing ->
            {:error,
             Changeset.add_error(
               changeset,
               :zone_ids,
               "does not exist: #{Enum.join(missing, ", ")}"
             )}
        end
    end
  end

  defp add_zone_ids_presence_error(changeset, zone_ids) do
    if Changeset.get_field(changeset, :scope) == "zones" and zone_ids == [] do
      Changeset.add_error(changeset, :zone_ids, "can't be blank")
    else
      changeset
    end
  end

  defp existing_zone_ids(repo, zone_ids) do
    valid_uuids = Enum.filter(zone_ids, &valid_uuid?/1)
    repo.all(from z in Zone, where: z.id in ^valid_uuids, select: z.id)
  end

  defp zone_ids_for_activation(repo, activation_id) do
    repo.all(
      from az in ActivationZone, where: az.activation_id == ^activation_id, select: az.zone_id
    )
  end

  defp valid_uuid?(id) when is_binary(id), do: match?({:ok, _}, Ecto.UUID.cast(id))
  defp valid_uuid?(_), do: false

  defp insert_activation_zones(_repo, _activation, []), do: {:ok, []}

  defp insert_activation_zones(repo, activation, zone_ids) do
    Enum.reduce_while(zone_ids, {:ok, []}, fn zone_id, {:ok, acc} ->
      %ActivationZone{}
      |> ActivationZone.changeset(%{activation_id: activation.id, zone_id: zone_id})
      |> repo.insert()
      |> case do
        {:ok, az} -> {:cont, {:ok, [az | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp normalize_attrs(attrs, opts) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.put_new("started_by_id", actor_id(opts))
    |> Map.put_new("started_at", DateTime.utc_now())
  end

  defp extract_zone_ids(attrs) do
    case Map.get(attrs, "zone_ids") do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, field, value), do: where(query, [a], field(a, ^field) == ^value)

  # ---------------------------------------------------------------------------
  # Audit snapshots (what lands in audit_logs.before/after)
  # ---------------------------------------------------------------------------

  defp activation_snapshot(%Activation{} = a),
    do: %{
      id: a.id,
      activation_type: a.activation_type,
      status: a.status,
      scope: a.scope,
      started_by_id: a.started_by_id,
      closed_by_id: a.closed_by_id,
      started_at: a.started_at,
      closed_at: a.closed_at
    }
end
