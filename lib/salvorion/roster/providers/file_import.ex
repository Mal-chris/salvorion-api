defmodule Salvorion.Roster.Providers.FileImport do
  @moduledoc """
  The FileImportProvider (Technical Foundation 03, section 2.2): reads a
  CSV file and turns each data row into a raw record for
  `Salvorion.Roster.Importer`. This is the interim path for getting a
  real roster in before any UNISS integration exists.

  Expected columns (a header row is required; order does not matter and
  unknown columns are ignored):

      type, id_number, first_name, last_name, email, phone,
      department_code, programme_code

  `email`, `phone`, `department_code` and `programme_code` may be blank.
  `department_code`/`programme_code` are resolved against the real
  Organisation records by their `code`. Only `staff` and `student` rows
  are imported: visitors are registered live, never bulk-loaded, so a
  `visitor` row is reported as a row error. Every person written gets
  `source: "roster"`.

  Row problems (unknown code, missing name or ID number, visitor rows)
  are reported per row, with `row` equal to the line number in the file
  (line 1 is the header), and the import continues. Only an unreadable
  file, malformed CSV, or a header missing required columns fails the
  whole run.
  """

  @behaviour Salvorion.Roster.Provider

  alias NimbleCSV.RFC4180, as: CSV
  alias Salvorion.Roster.Importer

  @provider "file_import"
  @source "roster"
  @columns ~w(type id_number first_name last_name email phone department_code programme_code)
  @required_columns ~w(type id_number first_name last_name)
  @column_keys Enum.map(@columns, &String.to_atom/1)

  @doc """
  Imports the CSV at `opts[:path]` in one audited run. Pass `:actor` for
  the audit trail when an admin triggers it. Returns
  `{:ok, %{total: n, errors: [%{row: n, reason: "..."}], import: import}}`
  or `{:error, reason}` when the file itself cannot be used.
  """
  @spec run(keyword) :: {:ok, Importer.result()} | {:error, term}
  def run(opts) do
    Importer.run(__MODULE__, opts,
      provider: @provider,
      source: @source,
      # so `row` in errors is the file line number, the header being line 1
      row_offset: 1,
      actor: Keyword.get(opts, :actor)
    )
  end

  @impl true
  def fetch_records(opts) do
    path = Keyword.fetch!(opts, :path)

    with {:ok, content} <- read(path),
         {:ok, header, rows} <- parse(content),
         :ok <- check_columns(header) do
      {:ok, Enum.map(rows, &row_to_record(header, &1))}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, strip_bom(content)}
      {:error, reason} -> {:error, "could not read #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Excel writes a UTF-8 byte-order mark at the start of the file, which
  # would otherwise become part of the first column name.
  defp strip_bom(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: rest
  defp strip_bom(content), do: content

  defp parse(content) do
    case CSV.parse_string(content, skip_headers: false) do
      [] ->
        {:error, "the file is empty"}

      [header | rows] ->
        {:ok, Enum.map(header, &(&1 |> String.trim() |> String.downcase())), rows}
    end
  rescue
    e in NimbleCSV.ParseError -> {:error, "malformed CSV: " <> Exception.message(e)}
  end

  defp check_columns(header) do
    case @required_columns -- header do
      [] -> :ok
      missing -> {:error, "missing columns: " <> Enum.join(missing, ", ")}
    end
  end

  # Zips a row against the header by column name; a short row leaves the
  # trailing columns nil, which the Importer reports as missing.
  defp row_to_record(header, cells) do
    by_name = header |> Enum.zip(cells) |> Map.new()
    Map.new(@column_keys, fn key -> {key, Map.get(by_name, Atom.to_string(key))} end)
  end
end
