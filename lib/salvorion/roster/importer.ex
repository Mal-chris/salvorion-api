defmodule Salvorion.Roster.Importer do
  @moduledoc """
  The one code path that turns a provider's raw records into `Person`
  rows. Every `Salvorion.Roster.Provider` produces the same raw_record
  shape; this module validates each one, resolves `department_code` and
  `programme_code` against the real Organisation records, upserts the
  person by `id_number`, and books the whole run as a `RosterImport`
  (FR-ROS-01, FR-ROS-04).

  Row problems are collected, never raised: a bad department code or a
  missing name on one row is reported in the result and the import
  continues with the next row. Only a provider that cannot produce any
  records at all (unreadable file, malformed header) fails the run.
  """

  alias Salvorion.Organisation.{Department, Programme}
  alias Salvorion.Repo
  alias Salvorion.Roster
  alias Salvorion.Roster.RosterImport

  @type row_error :: %{row: pos_integer, reason: String.t()}
  @type result :: %{total: non_neg_integer, errors: [row_error], import: %RosterImport{}}

  @importable_types ~w(staff student)

  @doc """
  Runs one complete import.

  `provider_module` implements `Salvorion.Roster.Provider`; `provider_opts`
  is passed to its `fetch_records/1` untouched. Options:

    * `:provider`   - required; the `RosterImport.provider` name
    * `:source`     - required; the `Person.source` every written row gets
      (`"roster"` for real imports, `"synthetic"` for generated data)
    * `:row_offset` - added to each record's 1-based position to produce
      the `row` reported in errors; a CSV provider passes 1 so `row`
      equals the file line number (line 1 being the header). Default 0.
    * `:actor`      - the acting user for the audit trail, or absent for
      an unattended run

  Returns `{:ok, %{total: n, errors: [%{row: n, reason: "..."}], import: import}}`
  once the `RosterImport` row has been completed, or `{:error, reason}`
  when the provider itself failed (the import row is still completed,
  with the failure recorded as its single error).
  """
  @spec run(module, keyword, keyword) :: {:ok, result} | {:error, term}
  def run(provider_module, provider_opts, opts) do
    provider = Keyword.fetch!(opts, :provider)
    audit_opts = Keyword.take(opts, [:actor])

    {:ok, import} = Roster.start_roster_import(provider, audit_opts)

    case provider_module.fetch_records(provider_opts) do
      {:ok, records} when is_list(records) ->
        {:ok, import_records(records, import, opts)}

      {:error, reason} ->
        errors = [%{row: 0, reason: "provider failed: " <> format_reason(reason)}]
        {:ok, _import} = Roster.complete_roster_import(import, 0, errors, audit_opts)
        {:error, reason}
    end
  end

  # Processes every record in order, then closes the import row.
  defp import_records(records, import, opts) do
    source = Keyword.fetch!(opts, :source)
    row_offset = Keyword.get(opts, :row_offset, 0)
    audit_opts = Keyword.take(opts, [:actor])
    codes = load_codes()

    errors =
      records
      |> Enum.with_index(row_offset + 1)
      |> Enum.reduce([], fn {record, row}, acc ->
        case import_record(record, source, codes, audit_opts) do
          :ok -> acc
          {:error, reason} -> [%{row: row, reason: reason} | acc]
        end
      end)
      |> Enum.reverse()

    total = length(records)
    {:ok, import} = Roster.complete_roster_import(import, total, errors, audit_opts)
    %{total: total, errors: errors, import: import}
  end

  @doc """
  Validates one raw record and writes it as a person with `source`.
  Exposed for tests; providers should go through `run/3`.
  """
  @spec import_record(map, String.t(), %{departments: map, programmes: map}, keyword) ::
          :ok | {:error, String.t()}
  def import_record(record, source, codes \\ load_codes(), audit_opts \\ []) do
    record = normalise(record)

    with :ok <- reject_blank(record),
         :ok <- validate_type(record.type),
         :ok <- validate_required(record),
         {:ok, department_id} <- resolve(codes.departments, record.department_code, "department"),
         {:ok, programme_id} <- resolve(codes.programmes, record.programme_code, "programme"),
         {:ok, _person} <-
           Roster.upsert_person_by_id_number(
             %{
               type: record.type,
               id_number: record.id_number,
               first_name: record.first_name,
               last_name: record.last_name,
               email: record.email,
               phone: record.phone,
               primary_department_id: department_id,
               programme_id: programme_id,
               source: source
             },
             audit_opts
           ) do
      :ok
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_reason(changeset)}
      {:error, reason} when is_binary(reason) -> {:error, reason}
    end
  end

  @doc "Department and programme `code => id` maps, read once per run."
  @spec load_codes() :: %{departments: map, programmes: map}
  def load_codes do
    %{
      departments: Map.new(Repo.all(Department), &{&1.code, &1.id}),
      programmes: Map.new(Repo.all(Programme), &{&1.code, &1.id})
    }
  end

  # Trims every string and turns blanks into nil so "missing" means the
  # same thing whether the provider sent nil, "" or "   ".
  defp normalise(record) do
    Map.new(
      [
        :type,
        :id_number,
        :first_name,
        :last_name,
        :email,
        :phone,
        :department_code,
        :programme_code
      ],
      fn key -> {key, blank_to_nil(Map.get(record, key))} end
    )
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  # A CSV blank line arrives as a record with every field nil.
  defp reject_blank(record) do
    if Enum.all?(record, fn {_k, v} -> is_nil(v) end),
      do: {:error, "blank row"},
      else: :ok
  end

  defp validate_type(nil), do: {:error, "missing type"}

  defp validate_type("visitor"),
    do: {:error, "visitors are registered on the spot, not imported from a roster"}

  defp validate_type(type) when type in @importable_types, do: :ok

  defp validate_type(type),
    do: {:error, "unknown type #{inspect(type)} (expected staff or student)"}

  defp validate_required(record) do
    missing =
      [:id_number, :first_name, :last_name]
      |> Enum.filter(&is_nil(Map.get(record, &1)))
      |> Enum.map(&Atom.to_string/1)

    case missing do
      [] -> :ok
      fields -> {:error, "missing " <> Enum.join(fields, ", ")}
    end
  end

  defp resolve(_map, nil, _label), do: {:ok, nil}

  defp resolve(map, code, label) do
    case Map.fetch(map, code) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "unknown #{label}_code #{inspect(code)}"}
    end
  end

  defp changeset_reason(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field} #{Enum.join(messages, ", ")}"
    end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
