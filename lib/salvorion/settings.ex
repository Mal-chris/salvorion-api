defmodule Salvorion.Settings do
  @moduledoc """
  The Settings context: key/value configuration for OSH decisions that
  were still pending at design time (Technical Foundation 03, section 5).
  Known keys and their documented values live in
  `Salvorion.Settings.Setting`'s moduledoc.

  Nothing is seeded. A key with no row takes the `default` the caller
  passes to `get_setting/2`, which is therefore where each Release 1
  default is declared (e.g. `Salvorion.Accountability` passes
  `"signed_in_only"` for `"student_accountability_rule"`).

  `value` is stored wrapped as `%{"value" => ...}` because the column is
  JSON; callers never see the wrapper.
  """

  import Ecto.Query, warn: false
  import Salvorion.Audit.Multi, only: [run_audited: 2, actor_id: 1]

  alias Ecto.Multi
  alias Salvorion.Audit
  alias Salvorion.Repo
  alias Salvorion.Settings.Setting

  @type opts :: Salvorion.Audit.Multi.opts()

  @doc "The stored value for `key`, or `default` when no row exists."
  @spec get_setting(String.t(), term) :: term
  def get_setting(key, default) when is_binary(key) do
    case Repo.get(Setting, key) do
      %Setting{value: %{"value" => value}} -> value
      nil -> default
    end
  end

  @doc """
  Creates or replaces the value for `key`, audited as `"setting.updated"`
  with the previous value (or nil) in `before`. A setting has no uuid, so
  the audit row's `entity_id` is nil and the key sits in the payload.
  """
  @spec put_setting(String.t(), term, opts) :: {:ok, %Setting{}} | {:error, Ecto.Changeset.t()}
  def put_setting(key, value, opts \\ []) when is_binary(key) do
    before = Repo.get(Setting, key)
    changeset = Setting.changeset(%Setting{}, %{key: key, value: %{"value" => value}})

    Multi.new()
    |> Multi.insert(:setting, changeset,
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: :key,
      returning: true
    )
    |> Multi.run(:audit, fn _repo, %{setting: setting} ->
      Audit.record(%{
        actor_user_id: actor_id(opts),
        action: "setting.updated",
        entity_type: "setting",
        entity_id: nil,
        before: before && %{key: key, value: before.value["value"]},
        after: %{key: key, value: setting.value["value"]}
      })
    end)
    |> run_audited(:setting)
  end
end
