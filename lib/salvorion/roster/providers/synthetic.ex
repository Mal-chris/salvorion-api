defmodule Salvorion.Roster.Providers.Synthetic do
  @moduledoc """
  The SyntheticRosterProvider (Technical Foundation 03, section 2.2):
  generates fictional staff and students for development, testing, the
  drill simulator and demonstrations.

  What is real and what is not:

    * Staff are spread round-robin across the REAL departments seeded from
      the OSH guide (Prompt 3), read from the database at run time; nothing
      about the department list is hardcoded here.
    * Students need a programme, but no real programme data exists yet
      (SRS Appendix A, "student grouping"). This provider therefore creates
      a small set of clearly-labelled SYNTHETIC programmes under one
      synthetic faculty, all with codes prefixed `SYN-`. They are NOT NCU
      programmes and must not be mistaken for them; the real programme
      list will be loaded separately once NCU supplies it.
    * ID numbers are `SYN-` followed by a zero-padded sequence
      (`SYN-000001`). The real NCU ID format is still open (SRS Appendix A,
      "ID barcode format") and no real ID will ever start with `SYN-`, so
      generated people can never collide with a future real import.
    * Names come from the invented lists below, constructed for this
      module. They are not drawn from any roster, real or remembered.
    * Every person written by this provider has `source: "synthetic"`, so
      a future "clear all synthetic data" admin action can find exactly
      these rows (and the `SYN-` faculty/programmes) and nothing else.

  Each run APPENDS: the ID sequence continues from the highest `SYN-`
  number already stored, so repeated runs accumulate people rather than
  overwriting or duplicating earlier ones.
  """

  @behaviour Salvorion.Roster.Provider

  import Ecto.Query, warn: false

  alias Salvorion.Organisation
  alias Salvorion.Organisation.{Department, Faculty, Programme}
  alias Salvorion.Repo
  alias Salvorion.Roster.Importer
  alias Salvorion.Roster.Person

  @provider "synthetic"
  @source "synthetic"
  @id_prefix "SYN-"
  @default_staff_count 150
  @default_student_count 1200

  # Placeholder faculty and programmes for synthetic students ONLY. Clearly
  # labelled so nobody mistakes them for NCU's real structure. The real
  # faculties/programmes are still unknown (Document 01, section 9).
  @synthetic_faculty %{name: "Synthetic Faculty (placeholder, not real)", code: "SYN-FAC"}
  @synthetic_programmes for n <- 1..6,
                            do: %{
                              name: "Synthetic Programme #{n} (placeholder, Faculty TBD)",
                              code: "SYN-PROG-#{String.pad_leading(Integer.to_string(n), 2, "0")}"
                            }

  # Invented for this provider. Deliberately literary/uncommon first names
  # and compound surnames so they read as fictional at a glance.
  @first_names ~w(
    Adrelle Bastienne Calder Dorrit Elowen Fenwick Galena Harlan Isolde
    Jorah Kestrel Larkin Merritt Nerissa Orrin Pascaline Quillon Rosalind
    Sorrel Tamsin Ulric Verity Wendel Xanthe Yorick Zephyrine Amaranth
    Briony Corwin Delphine Everard Fenella Garrick Hesper Ivo Junia Kellan
    Linnea Marisol Novella Osric Perrin Quenby Rowan Saffron Thessaly
    Ursuline Valerian Winnifred Ysolde
  )

  @last_names ~w(
    Quillbrook Farrowden Ashgrove Thornbury Wexcombe Brambleigh Corvane
    Dunmoor Ellisgate Fallowmere Greyhurst Hollowell Ironwick Jessamere
    Kilbrook Larkspur Marrowby Nethercott Oakhalter Pemberdine Quenston
    Ravensmere Saltmarsh Tallowick Umberfield Vexley Whitcombe Yarrowdale
    Ashdown Blackmere Cresswell Dovetail Emberly Foxhollow Gildersleeve
    Hawthorne Inglewood Juniperfield Knightsbridge Lindenmoor Mossbank
    Nightingale Orchardleigh Pennywhistle Quarrington Rookwood Silverdale
    Thistlewood Wintergreen
  )

  @doc """
  Generates and imports a synthetic roster in one audited run. Options:

    * `:staff_count`   - default #{@default_staff_count}
    * `:student_count` - default #{@default_student_count}
    * `:actor`         - acting user for the audit trail (optional)

  Returns `{:ok, %{total: n, errors: [...], import: %RosterImport{}}}` or
  `{:error, :no_departments}` when no real departments have been seeded.
  """
  @spec run(keyword) :: {:ok, Importer.result()} | {:error, term}
  def run(opts \\ []) do
    Importer.run(__MODULE__, opts,
      provider: @provider,
      source: @source,
      actor: Keyword.get(opts, :actor)
    )
  end

  @impl true
  def fetch_records(opts) do
    staff_count = Keyword.get(opts, :staff_count, @default_staff_count)
    student_count = Keyword.get(opts, :student_count, @default_student_count)

    departments = Organisation.list_departments()

    cond do
      departments == [] and staff_count > 0 ->
        {:error, :no_departments}

      true ->
        # Creating the placeholder programmes is a side effect of fetching,
        # but it is what makes the returned records importable on their
        # own; see the module doc for why they exist at all.
        programmes = ensure_synthetic_programmes()
        first_sequence = next_sequence()

        staff =
          departments
          |> assign(staff_count, first_sequence, fn %Department{code: code}, id_number ->
            record("staff", id_number, department_code: code)
          end)

        students =
          programmes
          |> assign(student_count, first_sequence + staff_count, fn %Programme{code: code},
                                                                    id_number ->
            record("student", id_number, programme_code: code)
          end)

        {:ok, staff ++ students}
    end
  end

  @doc "The `SYN-` prefix every synthetic id_number carries."
  @spec id_prefix() :: String.t()
  def id_prefix, do: @id_prefix

  # Walks the REAL list round-robin: person i goes to element rem(i, n).
  # With count >= length(targets) every target receives at least one
  # person; the lists themselves come from the database, never from here.
  defp assign(targets, count, first_sequence, build) when count > 0 do
    n = length(targets)

    Enum.map(0..(count - 1), fn i ->
      build.(Enum.at(targets, rem(i, n)), id_number(first_sequence + i))
    end)
  end

  defp assign(_targets, _count, _first_sequence, _build), do: []

  defp record(type, id_number, extra) do
    Map.merge(
      %{
        type: type,
        id_number: id_number,
        first_name: Enum.random(@first_names),
        last_name: Enum.random(@last_names),
        # .invalid is a reserved TLD (RFC 2606): these addresses cannot exist.
        email: String.downcase(id_number) <> "@synthetic.invalid",
        phone: nil,
        department_code: nil,
        programme_code: nil
      },
      Map.new(extra)
    )
  end

  defp id_number(sequence),
    do: @id_prefix <> String.pad_leading(Integer.to_string(sequence), 6, "0")

  # One past the highest SYN- sequence already in `people`, so a new run
  # appends rather than re-using numbers from an earlier one.
  defp next_sequence do
    prefix_len = String.length(@id_prefix) + 1

    max =
      Repo.one(
        from p in Person,
          where: like(p.id_number, ^(@id_prefix <> "%")),
          select:
            max(
              fragment(
                "CAST(SUBSTRING(? FROM CAST(? AS INTEGER)) AS INTEGER)",
                p.id_number,
                ^prefix_len
              )
            )
      )

    (max || 0) + 1
  end

  # Idempotent: creates the placeholder faculty and programmes only when
  # they are missing, so repeated runs share the same handful of codes.
  defp ensure_synthetic_programmes do
    faculty =
      case Organisation.get_faculty_by_code(@synthetic_faculty.code) do
        %Faculty{} = f ->
          f

        nil ->
          {:ok, f} = Organisation.create_faculty(@synthetic_faculty)
          f
      end

    Enum.map(@synthetic_programmes, fn attrs ->
      case Organisation.get_programme_by_code(attrs.code) do
        %Programme{} = p ->
          p

        nil ->
          {:ok, p} = Organisation.create_programme(Map.put(attrs, :faculty_id, faculty.id))
          p
      end
    end)
  end
end
