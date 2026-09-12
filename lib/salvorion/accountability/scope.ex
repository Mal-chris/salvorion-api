defmodule Salvorion.Accountability.Scope do
  @moduledoc """
  Resolves which people fall within a warden's or a zone's scope
  (FR-ROLL-01), and which zones a person is attributed to. Set-based
  throughout (joins and subqueries, never a loop over people) so it
  stays fast at ten times the dev roster's size (NFR-PERF-01/02).

  Reused by `Salvorion.Accountability` both for `"staff_by_location"`
  expected-presence (Prompt 6) and for the roll-call/dashboard reads
  (Prompt 7), so the definition of "a person's areas" lives in exactly
  one place: `person_area_pairs_query/0`.

  ## In scope (docs/DECISIONS.md)

  A person is in scope for a warden (or a zone drill-down) during an
  activation if EITHER:

    1. their roster location touches it — any of `person_areas/1` is in
       `scope.area_ids`; OR
    2. any of their events *in this activation* carries an `area_id` in
       `scope.area_ids`, or an `assembly_point_id` belonging to a zone in
       `scope.zone_ids`.

  Rule 2 is what puts a student under `"signed_in_only"`, or a visitor —
  neither has roster location data — on the list of the warden at the
  assembly point where they actually turned up.
  """

  import Ecto.Query, warn: false

  alias Salvorion.Accounts
  alias Salvorion.Accounts.User
  alias Salvorion.Accountability.AccountabilityEvent
  alias Salvorion.Activations.Activation
  alias Salvorion.Locations.{Area, DepartmentArea, Zone}
  alias Salvorion.Repo
  alias Salvorion.Roster.{Person, PersonDepartment}

  @doc """
  A query of every `(person_id, area_id)` pair: each person's
  `usual_area`, unioned with every area linked (via `department_areas`)
  to any of their departments (`primary_department` plus
  `person_departments`). This is the one definition of "a person's
  areas"; join against it, never loop over people.
  """
  @spec person_area_pairs_query() :: Ecto.Query.t()
  def person_area_pairs_query do
    usual =
      from p in Person,
        where: not is_nil(p.usual_area_id),
        select: %{person_id: p.id, area_id: p.usual_area_id}

    primary_dept_areas =
      from p in Person,
        join: da in DepartmentArea,
        on: da.department_id == p.primary_department_id,
        select: %{person_id: p.id, area_id: da.area_id}

    secondary_dept_areas =
      from pd in PersonDepartment,
        join: da in DepartmentArea,
        on: da.department_id == pd.department_id,
        select: %{person_id: pd.person_id, area_id: da.area_id}

    usual |> union(^primary_dept_areas) |> union(^secondary_dept_areas)
  end

  @doc "The area ids `person_id`'s roster location touches (usual area plus every department area)."
  @spec person_areas(binary) :: [binary]
  def person_areas(person_id) do
    Repo.all(
      from pa in subquery(person_area_pairs_query()),
        where: pa.person_id == ^person_id,
        select: pa.area_id
    )
  end

  @doc "The zone ids `person_id`'s roster areas belong to, via `person_area_pairs_query/0`."
  @spec person_zone_ids(binary) :: [binary]
  def person_zone_ids(person_id) do
    Repo.all(
      from pa in subquery(person_area_pairs_query()),
        join: a in Area,
        on: a.id == pa.area_id,
        where: pa.person_id == ^person_id,
        distinct: true,
        select: a.zone_id
    )
  end

  @doc """
  The zone ids `event`'s own location resolves to: its `area_id`'s zone,
  plus every zone served by its `assembly_point_id` (an assembly point
  may receive more than one zone). Used to widen a broadcast's zone_ids
  beyond roster attribution, so a walk-in with no roster location (a
  student, a visitor) still reaches the warden at the assembly point
  where they actually signed in.
  """
  @spec event_zone_ids(%AccountabilityEvent{}) :: [binary]
  def event_zone_ids(%AccountabilityEvent{area_id: nil, assembly_point_id: nil}), do: []

  def event_zone_ids(%AccountabilityEvent{} = event) do
    from_area =
      if event.area_id,
        do: from(a in Area, where: a.id == ^event.area_id, select: a.zone_id),
        else: from(a in Area, where: false, select: a.zone_id)

    from_assembly_point =
      if event.assembly_point_id,
        do: from(z in Zone, where: z.assembly_point_id == ^event.assembly_point_id, select: z.id),
        else: from(z in Zone, where: false, select: z.id)

    from_area
    |> union(^from_assembly_point)
    |> Repo.all()
    |> Enum.uniq()
  end

  @doc """
  `%{zone_ids: [...], area_ids: [...]}` for `user`'s warden assignments
  in effect as of `activation.started_at` (Task 1: fixed for the whole
  activation). A zone assignment contributes the zone and every area in
  it; an area assignment contributes that area and its zone. A user with
  no effective assignment gets `%{zone_ids: [], area_ids: []}` (an empty
  scope, not an error — callers check assignment existence separately).
  """
  @spec warden_scope(%User{}, %Activation{}) :: %{zone_ids: [binary], area_ids: [binary]}
  def warden_scope(user, %Activation{started_at: as_of}) do
    assignments = Accounts.effective_warden_assignments(user, as_of)

    zone_ids_direct = for %{zone_id: id} <- assignments, not is_nil(id), do: id
    area_ids_direct = for %{area_id: id} <- assignments, not is_nil(id), do: id

    areas_in_zones =
      Repo.all(from a in Area, where: a.zone_id in ^zone_ids_direct, select: a.id)

    zones_of_areas =
      Repo.all(from a in Area, where: a.id in ^area_ids_direct, select: a.zone_id)

    %{
      zone_ids: Enum.uniq(zone_ids_direct ++ zones_of_areas),
      area_ids: Enum.uniq(area_ids_direct ++ areas_in_zones)
    }
  end

  @doc """
  `%{zone_ids: [zone_id], area_ids: [...]}` for a single zone — the scope
  used for `list_roll_call_for_zone/2`, OSH/admin's drill-down.
  """
  @spec zone_scope(binary) :: %{zone_ids: [binary], area_ids: [binary]}
  def zone_scope(zone_id) do
    area_ids = Repo.all(from a in Area, where: a.zone_id == ^zone_id, select: a.id)
    %{zone_ids: [zone_id], area_ids: area_ids}
  end

  @doc """
  A query of every person_id in scope for `activation_id` given
  `%{zone_ids:, area_ids:}`, per the module doc's rules 1 and 2. Use as
  `where: p.id in subquery(in_scope_person_ids_query(...))`; never loop.
  """
  @spec in_scope_person_ids_query(binary, %{zone_ids: [binary], area_ids: [binary]}) ::
          Ecto.Query.t()
  def in_scope_person_ids_query(activation_id, %{zone_ids: zone_ids, area_ids: area_ids}) do
    by_roster =
      from pa in subquery(person_area_pairs_query()),
        where: pa.area_id in ^area_ids,
        select: pa.person_id

    by_event =
      from e in AccountabilityEvent,
        left_join: z in Zone,
        on: z.assembly_point_id == e.assembly_point_id,
        where: e.activation_id == ^activation_id,
        where: e.area_id in ^area_ids or z.id in ^zone_ids,
        select: e.person_id

    union(by_roster, ^by_event)
  end
end
