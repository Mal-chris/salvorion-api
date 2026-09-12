defmodule SalvorionWeb.PersonController do
  @moduledoc """
  The roster (Task 6). admin, osh_officer, warden (Document 10 section 2,
  directory information; FR-SIGN-02/03 — a warden needs the full roster
  for manual/name-search sign-in, not scoped to their own zone, since
  anyone could walk up to any assembly point).

  `index/2` is the one paginated list in this prompt (Task 1): every
  other list here is small enough that pagination is deferred, not
  forgotten (docs/DECISIONS.md).
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Roster
  alias Salvorion.Roster.Person

  # Only these query params are ever applied; anything else (a typo'd
  # filter name) is silently ignored rather than raising or misapplying,
  # per Task 1 — the response is the unfiltered (or partially filtered)
  # list, never a 500.
  @known_filters ~w(type department_id source)

  def index(conn, params) do
    filters = known_filters(params)
    {limit, offset} = pagination(params)

    people = Roster.list_people(filters ++ [limit: limit, offset: offset])
    total = Roster.count_people(filters)

    json(conn, %{
      data: Enum.map(people, &person_json/1),
      meta: %{total: total, limit: limit, offset: offset}
    })
  end

  def show(conn, %{"id" => id}) do
    json(conn, %{data: person_json(Roster.get_person!(id))})
  end

  @doc "GET /api/people/lookup?id_number=... — the scan-resolution path (FR-SIGN-01)."
  def lookup(conn, %{"id_number" => id_number}) do
    case Roster.get_person_by_id_number(id_number) do
      nil -> {:error, :unknown_person}
      person -> json(conn, %{data: person_json(person)})
    end
  end

  def lookup(_conn, _params), do: {:error, :unknown_person}

  defp known_filters(params) do
    for key <- @known_filters,
        value = params[key],
        not is_nil(value),
        do: {String.to_existing_atom(key), value}
  end

  defp pagination(params) do
    limit = params |> Map.get("limit") |> parse_int(50)
    offset = params |> Map.get("offset") |> parse_int(0)
    {limit, offset}
  end

  defp parse_int(nil, default), do: default

  defp parse_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> n
      _ -> default
    end
  end

  defp parse_int(_value, default), do: default

  defp person_json(%Person{} = p),
    do: %{
      id: p.id,
      type: p.type,
      id_number: p.id_number,
      first_name: p.first_name,
      last_name: p.last_name,
      email: p.email,
      phone: p.phone,
      source: p.source,
      primary_department_id: p.primary_department_id,
      programme_id: p.programme_id,
      usual_area_id: p.usual_area_id,
      visitor_host: p.visitor_host,
      visitor_expires_at: p.visitor_expires_at
    }
end
