defmodule Salvorion.Accountability do
  @moduledoc """
  The Accountability core: who is expected during an activation, the
  append-only event log of sign-ins, roll-call marks, visitor
  registrations and overrides, and the derived per-person status
  (FR-SIGN-01..07, FR-ROLL-01..07, FR-ROS-05; Document 08 sections 1-3;
  Technical Foundation 03, section 2.1).

  Four invariants hold throughout this module:

    * **I1** `AccountabilityEvent` rows are append-only. Nothing here
      updates or deletes one.
    * **I2** `server_timestamp` is set at ingest and is the only
      timestamp used for ordering. `client_timestamp` is recorded, and
      consulted once for the late-event rule, but never for ordering.
    * **I3** `client_uuid` is the idempotency key: ingesting an event
      whose `client_uuid` already exists returns the existing event and
      writes nothing (FR-SIGN-06).
    * **I4** `PersonStatus` is derived. `derive_status/2` rebuilds every
      field from the events for that (activation, person) plus whether an
      `ExpectedPresence` row exists. A warden's confirmation of a
      contradiction is itself an event (`contradiction_resolved`), so
      nothing on the row is unrecoverable.

  ## Expectation rules (Release 1; recorded in docs/DECISIONS.md)

  Computed by `initialise_for_activation/1` when an activation becomes
  active, over every `Person` regardless of `source`:

    * staff: campus scope, every staff person; zones scope, a staff
      person whose areas (usual area, plus every area linked to any of
      their departments) touch one of the activation's zones.
      `rule_applied = "staff_by_location"`.
    * students: by the `"student_accountability_rule"` setting —
      `"signed_in_only"` (default) expects nobody in advance;
      `"all_enrolled"` expects every student regardless of scope;
      `"timetable_expected"` is not implemented and raises at start.
    * visitors: never expected in advance.

  ## Status precedence (FR-ROLL-05, FR-ROLL-07)

  Kinds group as SIGN_IN (`scanned`, `manual`, `visitor_registered`),
  ROLL_CALL (`roll_call`), OVERRIDE (`override`) and RESOLUTION
  (`contradiction_resolved`, which never affects status or source).
  Highest first:

    1. any OVERRIDE: the latest override's status; a contradiction, if
       one is derivable, is recorded as resolved at that override's
       `server_timestamp`.
    2. else any SIGN_IN: `present`, sourced from the latest sign-in. If
       the latest ROLL_CALL says `absent`/`excused` it is a
       contradiction; it is resolved iff the latest RESOLUTION event's
       `server_timestamp` is later than that roll call's, with
       `contradiction_resolved_at` = the resolution's `server_timestamp`.
       A later roll_call/absent therefore reopens it.
    3. else any ROLL_CALL: the latest roll-call's status.
    4. else `unaccounted` if expected, otherwise no row.

  "Latest" is greatest `server_timestamp`, id as tiebreak.
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [audit: 7, run_audited: 2, actor_id: 1]

  alias Ecto.Changeset
  alias Ecto.Multi
  alias Salvorion.Accountability.{AccountabilityEvent, ExpectedPresence, PersonStatus}
  alias Salvorion.Accounts.User
  alias Salvorion.Activations.{Activation, ActivationZone}
  alias Salvorion.Audit
  alias Salvorion.Locations.{Area, DepartmentArea}
  alias Salvorion.Repo
  alias Salvorion.Roster
  alias Salvorion.Roster.{Person, PersonDepartment}
  alias Salvorion.Settings

  @type opts :: Salvorion.Audit.Multi.opts()

  @sign_in_kinds ~w(scanned manual visitor_registered)
  @roll_call_kinds ~w(roll_call)
  @override_kinds ~w(override)
  @resolution_kinds ~w(contradiction_resolved)

  @student_rule_key "student_accountability_rule"
  @default_student_rule "signed_in_only"
  @override_roles ~w(osh_officer admin)

  # Offline clients may upload after the activation closes; anything the
  # client stamped within this window of closed_at is still accepted
  # (docs/DECISIONS.md). A setting later, if OSH wants it tunable.
  @late_event_tolerance_seconds 5 * 60

  # Namespace for the per-person advisory lock (two-int form, so it
  # cannot collide with the single-bigint lock Activations uses).
  @person_lock_namespace 2

  # ---------------------------------------------------------------------------
  # Expected presence (Task 3)
  # ---------------------------------------------------------------------------

  @doc """
  Materialises the expected set for `activation`: one `ExpectedPresence`
  row per expected person and one `PersonStatus` row at `"unaccounted"`.
  Runs inside `Activations.start_activation/2`'s transaction. Idempotent:
  people already expected are skipped, and an existing status row is
  left alone (so a rerun never resets a derived status).

  Returns `{:ok, %{expected: n, rule: student_rule}}`. Raises
  `ArgumentError` if the student rule is `"timetable_expected"`, which
  Release 1 does not implement.
  """
  @spec initialise_for_activation(%Activation{}) :: {:ok, map}
  def initialise_for_activation(%Activation{} = activation) do
    student_rule = Settings.get_setting(@student_rule_key, @default_student_rule)

    student_ids =
      case student_rule do
        "signed_in_only" ->
          []

        "all_enrolled" ->
          Repo.all(from p in Person, where: p.type == "student", select: p.id)

        "timetable_expected" ->
          raise ArgumentError,
                "student_accountability_rule \"timetable_expected\" is not supported in " <>
                  "Release 1; set it to \"signed_in_only\" or \"all_enrolled\" before starting"

        other ->
          raise ArgumentError, "unknown student_accountability_rule #{inspect(other)}"
      end

    already_expected =
      Repo.all(
        from ep in ExpectedPresence,
          where: ep.activation_id == ^activation.id,
          select: ep.person_id
      )
      |> MapSet.new()

    expected =
      (Enum.map(expected_staff_ids(activation), &{&1, "staff_by_location"}) ++
         Enum.map(student_ids, &{&1, student_rule}))
      |> Enum.reject(fn {person_id, _} -> MapSet.member?(already_expected, person_id) end)

    now = DateTime.utc_now()

    presence_rows =
      for {person_id, rule} <- expected do
        %{
          id: Ecto.UUID.generate(),
          activation_id: activation.id,
          person_id: person_id,
          rule_applied: rule,
          inserted_at: now,
          updated_at: now
        }
      end

    status_rows =
      for {person_id, _} <- expected do
        %{
          id: Ecto.UUID.generate(),
          activation_id: activation.id,
          person_id: person_id,
          status: "unaccounted",
          inserted_at: now,
          updated_at: now
        }
      end

    presence_rows
    |> Enum.chunk_every(1000)
    |> Enum.each(&Repo.insert_all(ExpectedPresence, &1))

    status_rows
    |> Enum.chunk_every(1000)
    |> Enum.each(
      &Repo.insert_all(PersonStatus, &1,
        on_conflict: :nothing,
        conflict_target: [:activation_id, :person_id]
      )
    )

    {:ok, _} =
      Audit.record(%{
        actor_user_id: nil,
        action: "accountability.expectations_initialised",
        entity_type: "activation",
        entity_id: activation.id,
        after: %{
          scope: activation.scope,
          student_rule: student_rule,
          expected: length(expected),
          already_expected: MapSet.size(already_expected)
        }
      })

    {:ok, %{expected: length(expected), rule: student_rule}}
  end

  defp expected_staff_ids(%Activation{scope: "campus"}) do
    Repo.all(from p in Person, where: p.type == "staff", select: p.id)
  end

  defp expected_staff_ids(%Activation{scope: "zones", id: activation_id}) do
    zone_ids =
      from az in ActivationZone, where: az.activation_id == ^activation_id, select: az.zone_id

    area_ids = from a in Area, where: a.zone_id in subquery(zone_ids), select: a.id

    dept_ids =
      from da in DepartmentArea, where: da.area_id in subquery(area_ids), select: da.department_id

    secondary_member_ids =
      from pd in PersonDepartment,
        where: pd.department_id in subquery(dept_ids),
        select: pd.person_id

    Repo.all(
      from p in Person,
        where: p.type == "staff",
        where:
          p.usual_area_id in subquery(area_ids) or
            p.primary_department_id in subquery(dept_ids) or
            p.id in subquery(secondary_member_ids),
        select: p.id
    )
  end

  # ---------------------------------------------------------------------------
  # Event ingest (Task 4)
  # ---------------------------------------------------------------------------

  @doc """
  The single entry point for every sign-in, roll-call mark, visitor
  registration and override, live or uploaded later from an offline
  queue.

  `attrs` carries `client_uuid`, `activation_id`, `kind`, `status`,
  `recorded_by_id` (defaults to `opts[:actor]`), `client_timestamp`, and
  either `person_id` or `id_number`; optionally `device_id`,
  `assembly_point_id`, `area_id`, `note`. The audit actor defaults to
  `recorded_by_id`.

  Returns `{:ok, event, person_status}`, `{:ok, existing_event,
  :duplicate}` for a replayed `client_uuid` (I3), or one of
  `{:error, :unknown_person | :activation_not_found |
  :activation_not_started | :activation_closed | :override_not_permitted
  | changeset}`. Two events for the same person arriving together are
  both stored (I1); a per-person advisory lock serialises the status
  derivation so exactly one `PersonStatus` row results.
  """
  @spec ingest_event(map, opts) ::
          {:ok, %AccountabilityEvent{}, %PersonStatus{}}
          | {:ok, %AccountabilityEvent{}, :duplicate}
          | {:error, atom | Ecto.Changeset.t()}
  def ingest_event(attrs, opts \\ []) do
    attrs =
      attrs
      |> Map.new(fn {k, v} -> {to_string(k), v} end)
      |> Map.put_new("recorded_by_id", actor_id(opts))

    opts = Keyword.put_new(opts, :actor, attrs["recorded_by_id"])

    with {:ok, person} <- resolve_person(attrs),
         attrs = Map.put(attrs, "person_id", person.id),
         changeset = AccountabilityEvent.create_changeset(%AccountabilityEvent{}, attrs),
         :not_duplicate <- duplicate_check(Changeset.get_field(changeset, :client_uuid)),
         {:ok, changeset} <- valid_or_error(changeset),
         {:ok, activation} <- fetch_activation(Changeset.get_field(changeset, :activation_id)),
         :ok <-
           check_activation_accepts(activation, Changeset.get_field(changeset, :client_timestamp)),
         :ok <- check_override_permitted(changeset) do
      insert_and_derive(changeset, activation, person.id, opts)
    else
      {:duplicate, event} -> {:ok, event, :duplicate}
      {:error, _} = error -> error
    end
  end

  defp resolve_person(%{"id_number" => id_number}) when is_binary(id_number) do
    case Roster.get_person_by_id_number(id_number) do
      nil -> {:error, :unknown_person}
      %Person{} = person -> {:ok, person}
    end
  end

  defp resolve_person(%{"person_id" => person_id}) when is_binary(person_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(person_id),
         %Person{} = person <- Repo.get(Person, uuid) do
      {:ok, person}
    else
      _ -> {:error, :unknown_person}
    end
  end

  defp resolve_person(_), do: {:error, :unknown_person}

  defp duplicate_check(nil), do: :not_duplicate

  defp duplicate_check(client_uuid) do
    case Repo.get_by(AccountabilityEvent, client_uuid: client_uuid) do
      nil -> :not_duplicate
      %AccountabilityEvent{} = event -> {:duplicate, event}
    end
  end

  defp valid_or_error(%Changeset{valid?: true} = changeset), do: {:ok, changeset}
  defp valid_or_error(changeset), do: {:error, %{changeset | action: :insert}}

  defp fetch_activation(activation_id) do
    case Repo.get(Activation, activation_id) do
      nil -> {:error, :activation_not_found}
      %Activation{} = activation -> {:ok, activation}
    end
  end

  defp check_activation_accepts(%Activation{status: "scheduled"}, _),
    do: {:error, :activation_not_started}

  defp check_activation_accepts(%Activation{status: "active"}, _), do: :ok

  defp check_activation_accepts(%Activation{closed_at: closed_at}, client_timestamp) do
    deadline = DateTime.add(closed_at, @late_event_tolerance_seconds, :second)

    if DateTime.compare(client_timestamp, deadline) in [:lt, :eq],
      do: :ok,
      else: {:error, :activation_closed}
  end

  defp check_override_permitted(changeset) do
    if Changeset.get_field(changeset, :kind) in @override_kinds do
      case Repo.get(User, Changeset.get_field(changeset, :recorded_by_id)) do
        %User{role: role} when role in @override_roles -> :ok
        _ -> {:error, :override_not_permitted}
      end
    else
      :ok
    end
  end

  defp insert_and_derive(changeset, activation, person_id, opts) do
    multi =
      Multi.new()
      |> Multi.run(:lock, fn repo, _ -> acquire_person_lock(repo, activation.id, person_id) end)
      |> Multi.insert(:event, changeset)
      |> Multi.run(:person_status, fn _repo, _ ->
        upsert_derived_status(activation.id, person_id)
      end)
      |> maybe_audit_late_after_report(activation, opts)
      |> audit(
        :event,
        "accountability.event_ingested",
        "accountability_event",
        nil,
        &event_snapshot/1,
        opts
      )

    case Repo.transaction(multi) do
      {:ok, %{event: event, person_status: person_status}} ->
        {:ok, event, person_status}

      {:error, :event, %Changeset{errors: errors} = changeset, _} ->
        # Lost a race with an identical client_uuid: that is a duplicate, not an error (I3).
        if Keyword.has_key?(errors, :client_uuid),
          do:
            {:ok, Repo.get_by!(AccountabilityEvent, client_uuid: changeset.changes.client_uuid),
             :duplicate},
          else: {:error, changeset}

      {:error, _step, value, _} ->
        {:error, value}
    end
  end

  defp maybe_audit_late_after_report(multi, %Activation{status: "reported"} = activation, opts) do
    Multi.run(multi, :late_audit, fn _repo, %{event: event} ->
      Audit.record(%{
        actor_user_id: actor_id(opts),
        action: "accountability.late_event_after_report",
        entity_type: "activation",
        entity_id: activation.id,
        after: %{
          event_id: event.id,
          person_id: event.person_id,
          client_timestamp: event.client_timestamp,
          closed_at: activation.closed_at
        }
      })
    end)
  end

  defp maybe_audit_late_after_report(multi, _activation, _opts), do: multi

  defp acquire_person_lock(repo, activation_id, person_id) do
    key = :erlang.phash2({activation_id, person_id}, 2_147_483_648)
    repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@person_lock_namespace, key])
    {:ok, :locked}
  end

  # ---------------------------------------------------------------------------
  # Status derivation (Task 5)
  # ---------------------------------------------------------------------------

  @doc """
  The `PersonStatus` attrs for (`activation_id`, `person_id`) as a pure
  function of the events for that pair and whether an `ExpectedPresence`
  row exists (I4). Returns `:none` when there are no events and no
  expectation, meaning no row should exist.
  """
  @spec derive_status(binary, binary) :: map | :none
  def derive_status(activation_id, person_id) do
    events =
      Repo.all(
        from e in AccountabilityEvent,
          where: e.activation_id == ^activation_id and e.person_id == ^person_id,
          order_by: [desc: e.server_timestamp, desc: e.id]
      )

    expected? =
      Repo.exists?(
        from ep in ExpectedPresence,
          where: ep.activation_id == ^activation_id and ep.person_id == ^person_id
      )

    derive(events, expected?, activation_id, person_id)
  end

  # `events` must be newest-first (server_timestamp desc, id desc).
  defp derive(events, expected?, activation_id, person_id) do
    override = Enum.find(events, &(&1.kind in @override_kinds))
    sign_in = Enum.find(events, &(&1.kind in @sign_in_kinds))
    roll_call = Enum.find(events, &(&1.kind in @roll_call_kinds))
    resolution = Enum.find(events, &(&1.kind in @resolution_kinds))

    contradicting =
      if sign_in && roll_call && roll_call.status in ~w(absent excused), do: roll_call, else: nil

    base = %{activation_id: activation_id, person_id: person_id}

    cond do
      override ->
        Map.merge(base, %{
          status: override.status,
          source_event_id: override.id,
          contradicting_event_id: contradicting && contradicting.id,
          contradiction_resolved_at: contradicting && override.server_timestamp
        })

      sign_in ->
        Map.merge(base, %{
          status: "present",
          source_event_id: sign_in.id,
          contradicting_event_id: contradicting && contradicting.id,
          contradiction_resolved_at: resolved_at(contradicting, resolution)
        })

      roll_call ->
        Map.merge(base, %{
          status: roll_call.status,
          source_event_id: roll_call.id,
          contradicting_event_id: nil,
          contradiction_resolved_at: nil
        })

      expected? ->
        Map.merge(base, %{
          status: "unaccounted",
          source_event_id: nil,
          contradicting_event_id: nil,
          contradiction_resolved_at: nil
        })

      true ->
        :none
    end
  end

  # A warden's confirmation resolves the contradiction only if it came
  # after the contradicting roll call; a later roll_call/absent reopens it.
  defp resolved_at(%AccountabilityEvent{} = contradicting, %AccountabilityEvent{} = resolution) do
    if DateTime.compare(resolution.server_timestamp, contradicting.server_timestamp) == :gt,
      do: resolution.server_timestamp,
      else: nil
  end

  defp resolved_at(_contradicting, _resolution), do: nil

  defp upsert_derived_status(activation_id, person_id) do
    existing = Repo.get_by(PersonStatus, activation_id: activation_id, person_id: person_id)

    case derive_status(activation_id, person_id) do
      :none ->
        {:ok, existing}

      attrs ->
        (existing || %PersonStatus{})
        |> PersonStatus.changeset(attrs)
        |> Repo.insert_or_update()
    end
  end

  @doc """
  Derives and upserts the `PersonStatus` row for one person (I4),
  under the same per-person lock ingest uses. Audited as
  `"accountability.status_rebuilt"`. Returns `{:ok, person_status | nil}`.
  """
  @spec rebuild_person_status(binary, binary, opts) ::
          {:ok, %PersonStatus{} | nil} | {:error, term}
  def rebuild_person_status(activation_id, person_id, opts \\ []) do
    before = Repo.get_by(PersonStatus, activation_id: activation_id, person_id: person_id)

    Multi.new()
    |> Multi.run(:lock, fn repo, _ -> acquire_person_lock(repo, activation_id, person_id) end)
    |> Multi.run(:person_status, fn _repo, _ ->
      upsert_derived_status(activation_id, person_id)
    end)
    |> Multi.run(:audit, fn _repo, %{person_status: status} ->
      Audit.record(%{
        actor_user_id: actor_id(opts),
        action: "accountability.status_rebuilt",
        entity_type: "person_status",
        entity_id: status && status.id,
        before: before && status_snapshot(before),
        after: status && status_snapshot(status)
      })
    end)
    |> run_audited(:person_status)
  end

  @doc """
  Rebuilds the status of every person with an event or an expectation
  in `activation_id` (repair). One audit row,
  `"accountability.statuses_rebuilt"`, with the count. Returns
  `{:ok, count}`.
  """
  @spec rebuild_activation_statuses(binary, opts) :: {:ok, non_neg_integer} | {:error, term}
  def rebuild_activation_statuses(activation_id, opts \\ []) do
    from_events =
      from e in AccountabilityEvent, where: e.activation_id == ^activation_id, select: e.person_id

    from_expected =
      from ep in ExpectedPresence, where: ep.activation_id == ^activation_id, select: ep.person_id

    person_ids = Enum.uniq(Repo.all(from_events) ++ Repo.all(from_expected))

    Multi.new()
    |> Multi.run(:rebuilt, fn repo, _ ->
      Enum.reduce_while(person_ids, {:ok, 0}, fn person_id, {:ok, n} ->
        acquire_person_lock(repo, activation_id, person_id)

        case upsert_derived_status(activation_id, person_id) do
          {:ok, _} -> {:cont, {:ok, n + 1}}
          {:error, _} = error -> {:halt, error}
        end
      end)
    end)
    |> Multi.run(:audit, fn _repo, %{rebuilt: count} ->
      Audit.record(%{
        actor_user_id: actor_id(opts),
        action: "accountability.statuses_rebuilt",
        entity_type: "activation",
        entity_id: activation_id,
        after: %{rebuilt: count}
      })
    end)
    |> run_audited(:rebuilt)
  end

  # ---------------------------------------------------------------------------
  # Resolving a contradiction (Task 6)
  # ---------------------------------------------------------------------------

  @doc """
  The warden's "confirm" (Document 11, section 1.5): ingests a
  `"contradiction_resolved"` event for (`activation_id`, `person_id`)
  through `ingest_event/2` (same idempotency, same audit), so the
  confirmation lives in the event log and survives any rebuild (I4).
  Derivation then sets `contradiction_resolved_at` to that event's
  `server_timestamp`; status and `contradicting_event_id` are unchanged.
  `opts[:actor]` is the recording user; `opts[:client_uuid]` and
  `opts[:client_timestamp]` may be supplied by an offline client, else
  generated here. Returns `{:error, :no_open_contradiction}` if there is
  nothing to confirm.
  """
  @spec resolve_contradiction(binary, binary, opts) ::
          {:ok, %PersonStatus{}} | {:error, atom | Ecto.Changeset.t()}
  def resolve_contradiction(activation_id, person_id, opts \\ []) do
    replayed? =
      case Keyword.get(opts, :client_uuid) do
        nil -> false
        uuid -> Repo.exists?(from e in AccountabilityEvent, where: e.client_uuid == ^uuid)
      end

    case Repo.get_by(PersonStatus, activation_id: activation_id, person_id: person_id) do
      %PersonStatus{} = status when replayed? ->
        {:ok, status}

      %PersonStatus{contradicting_event_id: id, contradiction_resolved_at: nil}
      when is_binary(id) ->
        attrs = %{
          client_uuid: Keyword.get_lazy(opts, :client_uuid, &Ecto.UUID.generate/0),
          client_timestamp: Keyword.get_lazy(opts, :client_timestamp, &DateTime.utc_now/0),
          activation_id: activation_id,
          person_id: person_id,
          kind: "contradiction_resolved",
          status: "present",
          note: Keyword.get(opts, :note)
        }

        case ingest_event(attrs, Keyword.take(opts, [:actor])) do
          {:ok, _event, %PersonStatus{} = status} ->
            {:ok, status}

          {:ok, _event, :duplicate} ->
            {:ok, Repo.get_by!(PersonStatus, activation_id: activation_id, person_id: person_id)}

          {:error, _} = error ->
            error
        end

      _ ->
        {:error, :no_open_contradiction}
    end
  end

  # ---------------------------------------------------------------------------
  # Counts and history (Task 7)
  # ---------------------------------------------------------------------------

  @spec count_statuses(binary) :: %{
          present: non_neg_integer,
          absent: non_neg_integer,
          excused: non_neg_integer,
          unaccounted: non_neg_integer
        }
  def count_statuses(activation_id) do
    counts =
      Repo.all(
        from ps in PersonStatus,
          where: ps.activation_id == ^activation_id,
          group_by: ps.status,
          select: {ps.status, count(ps.id)}
      )
      |> Map.new()

    %{
      present: Map.get(counts, "present", 0),
      absent: Map.get(counts, "absent", 0),
      excused: Map.get(counts, "excused", 0),
      unaccounted: Map.get(counts, "unaccounted", 0)
    }
  end

  @spec count_open_contradictions(binary) :: non_neg_integer
  def count_open_contradictions(activation_id) do
    Repo.aggregate(
      from(ps in PersonStatus,
        where:
          ps.activation_id == ^activation_id and not is_nil(ps.contradicting_event_id) and
            is_nil(ps.contradiction_resolved_at)
      ),
      :count
    )
  end

  @spec count_events(binary) :: non_neg_integer
  def count_events(activation_id) do
    Repo.aggregate(
      from(e in AccountabilityEvent, where: e.activation_id == ^activation_id),
      :count
    )
  end

  @doc "One person's full event history in an activation, oldest first by `server_timestamp` (I2)."
  @spec list_events_for_person(binary, binary) :: [%AccountabilityEvent{}]
  def list_events_for_person(activation_id, person_id) do
    Repo.all(
      from e in AccountabilityEvent,
        where: e.activation_id == ^activation_id and e.person_id == ^person_id,
        order_by: [asc: e.server_timestamp, asc: e.id]
    )
  end

  @spec get_person_status(binary, binary) :: %PersonStatus{} | nil
  def get_person_status(activation_id, person_id),
    do: Repo.get_by(PersonStatus, activation_id: activation_id, person_id: person_id)

  # ---------------------------------------------------------------------------
  # Audit snapshots
  # ---------------------------------------------------------------------------

  defp event_snapshot(%AccountabilityEvent{} = e),
    do: %{
      id: e.id,
      client_uuid: e.client_uuid,
      activation_id: e.activation_id,
      person_id: e.person_id,
      kind: e.kind,
      status: e.status,
      recorded_by_id: e.recorded_by_id,
      device_id: e.device_id,
      assembly_point_id: e.assembly_point_id,
      area_id: e.area_id,
      note: e.note,
      client_timestamp: e.client_timestamp,
      server_timestamp: e.server_timestamp
    }

  defp status_snapshot(%PersonStatus{} = s),
    do: %{
      id: s.id,
      activation_id: s.activation_id,
      person_id: s.person_id,
      status: s.status,
      source_event_id: s.source_event_id,
      contradicting_event_id: s.contradicting_event_id,
      contradiction_resolved_at: s.contradiction_resolved_at
    }
end
