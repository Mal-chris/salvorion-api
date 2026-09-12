defmodule Salvorion.Audit.Multi do
  @moduledoc """
  Helpers for recording an audit row in the same `Ecto.Multi` transaction
  as the change it describes. This is the one convention every context
  uses for audited writes (Accounts, Organisation, Locations, ...); it
  funnels through `Salvorion.Audit.record/1`, which remains the only code
  path that writes to `audit_logs`.

  Typical use:

      Multi.new()
      |> Multi.insert(:zone, Zone.changeset(%Zone{}, attrs))
      |> audit(:zone, "zone.created", "zone", nil, &zone_snapshot/1, opts)
      |> run_audited(:zone)

  `opts` is the keyword list every audited context function accepts; its
  `:actor` (a `%User{}` or a user id) becomes `actor_user_id`. Pass no
  actor only where there is genuinely no acting user (seeds, system jobs).
  """

  alias Ecto.Multi
  alias Salvorion.Accounts.User
  alias Salvorion.Audit
  alias Salvorion.Repo

  @type opts :: [actor: %User{} | binary | nil]

  @doc """
  Appends an `:audit` step that records `action` against the entity
  produced by the earlier Multi step named `step`.

    * `before` - snapshot map of the entity before the change, or nil
    * `after_fun` - function from the written entity to its snapshot map,
      or nil when the entity no longer exists (a delete)

  `entity_id` is taken from the written entity's `id`.
  """
  @spec audit(
          Multi.t(),
          atom,
          String.t(),
          String.t(),
          map | nil,
          (struct -> map) | nil,
          opts
        ) :: Multi.t()
  def audit(multi, step, action, entity_type, before, after_fun, opts \\ []) do
    Multi.run(multi, :audit, fn _repo, results ->
      entity = Map.fetch!(results, step)

      Audit.record(%{
        actor_user_id: actor_id(opts),
        action: action,
        entity_type: entity_type,
        entity_id: entity.id,
        before: before,
        after: if(after_fun, do: after_fun.(entity), else: nil)
      })
    end)
  end

  @doc """
  Runs the Multi in a transaction and unwraps the result of step `key`:
  `{:ok, entity}` or `{:error, changeset}` (the failing step's value).
  """
  @spec run_audited(Multi.t(), atom) :: {:ok, struct} | {:error, term}
  def run_audited(multi, key) do
    case Repo.transaction(multi) do
      {:ok, results} -> {:ok, Map.fetch!(results, key)}
      {:error, _step, value, _} -> {:error, value}
    end
  end

  @doc "The actor user id from an `opts` keyword list, or nil."
  @spec actor_id(opts) :: binary | nil
  def actor_id(opts) do
    case Keyword.get(opts, :actor) do
      %User{id: id} -> id
      id when is_binary(id) -> id
      nil -> nil
    end
  end
end
