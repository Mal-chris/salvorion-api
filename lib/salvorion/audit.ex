defmodule Salvorion.Audit do
  @moduledoc """
  The Audit context: an append-only trail of who did what, to what, and when
  (FR-AUD-01 to FR-AUD-03).

  `record/1` is the ONLY code path that writes to `audit_logs`. This module
  deliberately exposes no update or delete function (FR-AUD-02), and nothing
  else in the codebase may call `Repo.update`/`Repo.delete` against
  `Salvorion.Audit.AuditLog`.
  """

  import Ecto.Query, warn: false

  alias Salvorion.Audit.AuditLog
  alias Salvorion.Repo

  @type attrs :: %{
          optional(:actor_user_id) => binary | nil,
          required(:action) => String.t(),
          required(:entity_type) => String.t(),
          optional(:entity_id) => binary | nil,
          optional(:before) => map | nil,
          optional(:after) => map | nil
        }

  @doc """
  Appends one audit row.

  `actor_user_id` may be nil only for actions with genuinely no acting user
  (system jobs such as the visitor purge, or the very first bootstrap seed).
  Returns `{:ok, %AuditLog{}}` or `{:error, changeset}`.
  """
  @spec record(attrs) :: {:ok, %AuditLog{}} | {:error, Ecto.Changeset.t()}
  def record(attrs) when is_map(attrs) do
    %AuditLog{}
    |> AuditLog.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Lists audit rows, newest first, for the (future) admin screen.

  Filters (all optional, as a keyword list or map):

    * `:entity_type`   - exact match, e.g. `"user"`
    * `:entity_id`     - exact match
    * `:actor_user_id` - exact match
    * `:action`        - exact match, e.g. `"user.deactivated"`
    * `:from`          - `DateTime`; rows inserted at or after it
    * `:to`            - `DateTime`; rows inserted before it
    * `:limit`         - defaults to 100
  """
  @spec list_audit_logs(keyword | map) :: [%AuditLog{}]
  def list_audit_logs(filters \\ []) do
    filters = Map.new(filters)

    AuditLog
    |> filter_eq(:entity_type, filters[:entity_type])
    |> filter_eq(:entity_id, filters[:entity_id])
    |> filter_eq(:actor_user_id, filters[:actor_user_id])
    |> filter_eq(:action, filters[:action])
    |> filter_from(filters[:from])
    |> filter_to(filters[:to])
    |> order_by([l], desc: l.inserted_at, desc: l.id)
    |> limit(^Map.get(filters, :limit, 100))
    |> Repo.all()
  end

  defp filter_eq(query, _field, nil), do: query
  defp filter_eq(query, field, value), do: where(query, [l], field(l, ^field) == ^value)

  defp filter_from(query, nil), do: query
  defp filter_from(query, %DateTime{} = from), do: where(query, [l], l.inserted_at >= ^from)

  defp filter_to(query, nil), do: query
  defp filter_to(query, %DateTime{} = to), do: where(query, [l], l.inserted_at < ^to)
end
