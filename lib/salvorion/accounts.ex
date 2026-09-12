defmodule Salvorion.Accounts do
  @moduledoc """
  The Accounts context: users, their devices, warden assignments, and token
  issuance.

  Every function that creates, updates or deactivates something takes an
  `opts` keyword list whose `:actor` (a `%User{}` or a user id) names the
  authenticated user performing the action; the change and its audit row are
  written in one transaction via `Salvorion.Audit.record/1`. Pass no actor
  only where there is genuinely no acting user (the bootstrap seed).

  Users are never deleted: `deactivate_user/2` sets `active: false`
  (Document 10, section 2). Devices are never deleted either:
  `revoke_device/2` sets `revoked_at` (Document 13, finding 2.5).
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias Salvorion.Accounts.{Device, Guardian, User, WardenAssignment}
  alias Salvorion.Audit
  alias Salvorion.Repo

  @type opts :: [actor: %User{} | binary | nil]

  # ---------------------------------------------------------------------------
  # Users
  # ---------------------------------------------------------------------------

  @doc """
  Registers a user. `attrs` needs `:email`, `:password`, `:role` and may
  include `:person_id`. Returns `{:ok, user}` or `{:error, changeset}`.
  """
  @spec register_user(map, opts) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def register_user(attrs, opts \\ []) do
    changeset =
      %User{}
      |> User.changeset(attrs)
      |> Ecto.Changeset.validate_required([:password])
      |> Ecto.Changeset.validate_length(:password, min: 8, max: 128)

    Multi.new()
    |> Multi.insert(:user, changeset)
    |> audit(:user, "user.registered", "user", & &1.user.id, nil, &user_snapshot(&1.user), opts)
    |> run_multi(:user)
  end

  @doc """
  Verifies the email/password pair against the stored argon2 hash.

  Returns `{:ok, user}` or `{:error, :invalid_credentials}`. The same error
  is returned whether the email is unknown, the password is wrong, or the
  user is deactivated, and a dummy hash check runs when no user matches so
  response timing does not reveal which case occurred.
  """
  @spec authenticate_user(String.t(), String.t()) ::
          {:ok, %User{}} | {:error, :invalid_credentials}
  def authenticate_user(email, password) when is_binary(email) and is_binary(password) do
    user = Repo.get_by(User, email: String.downcase(String.trim(email)))

    cond do
      is_nil(user) ->
        Argon2.no_user_verify()
        {:error, :invalid_credentials}

      Argon2.verify_pass(password, user.password_hash) and user.active ->
        {:ok, user}

      true ->
        {:error, :invalid_credentials}
    end
  end

  def authenticate_user(_, _), do: {:error, :invalid_credentials}

  @spec get_user!(binary) :: %User{}
  def get_user!(id), do: Repo.get!(User, id)

  @spec get_user(binary) :: %User{} | nil
  def get_user(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(User, uuid)
      :error -> nil
    end
  end

  @spec list_users() :: [%User{}]
  def list_users do
    User
    |> order_by([u], asc: u.email)
    |> Repo.all()
  end

  @doc "Changes a user's role. Returns `{:ok, user}` or `{:error, changeset}`."
  @spec update_user_role(%User{}, String.t(), opts) ::
          {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def update_user_role(%User{} = user, role, opts \\ []) do
    before = user_snapshot(user)

    Multi.new()
    |> Multi.update(:user, User.changeset(user, %{role: role}))
    |> audit(
      :user,
      "user.role_changed",
      "user",
      & &1.user.id,
      before,
      &user_snapshot(&1.user),
      opts
    )
    |> run_multi(:user)
  end

  @doc """
  Deactivates a user by setting `active: false`. User rows are retained for
  the audit trail and are never deleted (Document 10, section 2).
  """
  @spec deactivate_user(%User{}, opts) :: {:ok, %User{}} | {:error, Ecto.Changeset.t()}
  def deactivate_user(%User{} = user, opts \\ []) do
    before = user_snapshot(user)

    Multi.new()
    |> Multi.update(:user, User.changeset(user, %{active: false}))
    |> audit(
      :user,
      "user.deactivated",
      "user",
      & &1.user.id,
      before,
      &user_snapshot(&1.user),
      opts
    )
    |> run_multi(:user)
  end

  # ---------------------------------------------------------------------------
  # Devices
  # ---------------------------------------------------------------------------

  @doc """
  Registers a device for a user. `attrs` needs `:platform`
  (`"android" | "ios" | "web"`). Returns `{:ok, device}` or `{:error, changeset}`.
  """
  @spec register_device(%User{}, map, opts) :: {:ok, %Device{}} | {:error, Ecto.Changeset.t()}
  def register_device(%User{id: user_id}, attrs, opts \\ []) do
    attrs = attrs |> Map.new() |> Map.drop([:user_id, "user_id"]) |> Map.put(:user_id, user_id)

    Multi.new()
    |> Multi.insert(:device, Device.changeset(%Device{}, attrs))
    |> audit(
      :device,
      "device.registered",
      "device",
      & &1.device.id,
      nil,
      &device_snapshot(&1.device),
      opts
    )
    |> run_multi(:device)
  end

  @spec get_device(binary) :: %Device{} | nil
  def get_device(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Device, uuid)
      :error -> nil
    end
  end

  @doc """
  Revokes a device by setting `revoked_at` (Document 13, finding 2.5). The
  row is kept; tokens carrying this device's id are rejected from then on.
  Revoking an already-revoked device is a no-op that keeps the original
  timestamp.
  """
  @spec revoke_device(%Device{}, opts) :: {:ok, %Device{}} | {:error, Ecto.Changeset.t()}
  def revoke_device(device, opts \\ [])

  def revoke_device(%Device{revoked_at: %DateTime{}} = device, _opts), do: {:ok, device}

  def revoke_device(%Device{} = device, opts) do
    before = device_snapshot(device)
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.update(:device, Device.changeset(device, %{revoked_at: now}))
    |> audit(
      :device,
      "device.revoked",
      "device",
      & &1.device.id,
      before,
      &device_snapshot(&1.device),
      opts
    )
    |> run_multi(:device)
  end

  @doc "True when the device does not exist or has `revoked_at` set."
  @spec device_revoked?(binary) :: boolean
  def device_revoked?(device_id) do
    case Ecto.UUID.cast(device_id) do
      {:ok, uuid} ->
        query = from d in Device, where: d.id == ^uuid and is_nil(d.revoked_at), select: true
        not Repo.exists?(query)

      :error ->
        true
    end
  end

  # ---------------------------------------------------------------------------
  # Warden assignments
  # ---------------------------------------------------------------------------

  @doc """
  Assigns a user responsibility for exactly one zone or one area over a date
  range.

    * `scope` - `{:zone, zone_id}` or `{:area, area_id}`
    * `date_range` - `{starts_at, ends_at}` (`ends_at` may be nil for
      open-ended) or a `Date.Range`

  Exactly-one-of zone/area is validated by the schema changeset before the
  database `exactly_one_of_zone_or_area` constraint is reached.
  """
  @spec assign_warden(
          binary,
          {:zone | :area, binary},
          {Date.t(), Date.t() | nil} | Date.Range.t(),
          opts
        ) ::
          {:ok, %WardenAssignment{}} | {:error, Ecto.Changeset.t()}
  def assign_warden(user_id, scope, date_range, opts \\ []) do
    {starts_at, ends_at} = normalise_range(date_range)

    attrs =
      %{user_id: user_id, starts_at: starts_at, ends_at: ends_at}
      |> Map.merge(scope_attrs(scope))

    changeset =
      %WardenAssignment{}
      |> WardenAssignment.changeset(attrs)
      |> validate_date_order()

    Multi.new()
    |> Multi.insert(:assignment, changeset)
    |> audit(
      :assignment,
      "warden_assignment.created",
      "warden_assignment",
      & &1.assignment.id,
      nil,
      &assignment_snapshot(&1.assignment),
      opts
    )
    |> run_multi(:assignment)
  end

  defp scope_attrs({:zone, id}), do: %{zone_id: id}
  defp scope_attrs({:area, id}), do: %{area_id: id}
  # Anything else falls through to the changeset, which reports the missing scope.
  defp scope_attrs(_), do: %{}

  defp normalise_range(%Date.Range{first: first, last: last}), do: {first, last}
  defp normalise_range({%Date{} = starts_at, ends_at}), do: {starts_at, ends_at}
  defp normalise_range(_), do: {nil, nil}

  defp validate_date_order(changeset) do
    starts_at = Ecto.Changeset.get_field(changeset, :starts_at)
    ends_at = Ecto.Changeset.get_field(changeset, :ends_at)

    if starts_at && ends_at && Date.compare(ends_at, starts_at) == :lt do
      Ecto.Changeset.add_error(changeset, :ends_at, "must be on or after starts_at")
    else
      changeset
    end
  end

  # ---------------------------------------------------------------------------
  # Tokens
  # ---------------------------------------------------------------------------

  @doc """
  Issues an access token (15 min) and a refresh token (30 days) for a user
  (Document 10, section 4). Pass `device_id: id` to bind both tokens to a
  registered device so `revoke_device/2` invalidates them.

  Returns `{:ok, %{access_token: ..., refresh_token: ..., expires_in: 900,
  token_type: "Bearer"}}` or `{:error, reason}`.
  """
  @spec issue_tokens(%User{}, device_id: binary | nil) :: {:ok, map} | {:error, term}
  def issue_tokens(%User{} = user, opts \\ []) do
    extra =
      case Keyword.get(opts, :device_id) do
        nil -> %{}
        device_id -> %{"device_id" => device_id}
      end

    with {:ok, access, access_claims} <-
           Guardian.encode_and_sign(user, extra, token_type: "access"),
         {:ok, refresh, _} <- Guardian.encode_and_sign(user, extra, token_type: "refresh") do
      {:ok,
       %{
         access_token: access,
         refresh_token: refresh,
         token_type: "Bearer",
         expires_in: access_claims["exp"] - access_claims["iat"]
       }}
    end
  end

  @doc """
  Exchanges a valid refresh token for a fresh access/refresh pair. Re-checks
  that the user is still active and the bound device (if any) is not revoked.
  """
  @spec refresh_tokens(String.t()) :: {:ok, map} | {:error, :invalid_token}
  def refresh_tokens(refresh_token) when is_binary(refresh_token) do
    with {:ok, claims} <- Guardian.decode_and_verify(refresh_token, %{"typ" => "refresh"}),
         %User{active: true} = user <- get_user(claims["sub"]),
         false <- device_revoked_claim?(claims) do
      issue_tokens(user, device_id: claims["device_id"])
    else
      _ -> {:error, :invalid_token}
    end
  end

  defp device_revoked_claim?(%{"device_id" => id}) when is_binary(id), do: device_revoked?(id)
  defp device_revoked_claim?(_), do: false

  # ---------------------------------------------------------------------------
  # Audit helpers
  # ---------------------------------------------------------------------------

  # Appends an audit step to a Multi. `entity_id_fun` and `after_fun` receive
  # the Multi's results so far so they can read the freshly written row.
  defp audit(multi, _step, action, entity_type, entity_id_fun, before, after_fun, opts) do
    Multi.run(multi, :audit, fn _repo, results ->
      Audit.record(%{
        actor_user_id: actor_id(opts),
        action: action,
        entity_type: entity_type,
        entity_id: entity_id_fun.(results),
        before: before,
        after: after_fun.(results)
      })
    end)
  end

  defp run_multi(multi, key) do
    case Repo.transaction(multi) do
      {:ok, results} -> {:ok, Map.fetch!(results, key)}
      {:error, _step, changeset, _} -> {:error, changeset}
    end
  end

  defp actor_id(opts) do
    case Keyword.get(opts, :actor) do
      %User{id: id} -> id
      id when is_binary(id) -> id
      nil -> nil
    end
  end

  # Snapshots are what lands in audit_logs.before/after. They never include
  # the password hash.
  defp user_snapshot(%User{} = u),
    do: %{id: u.id, email: u.email, role: u.role, active: u.active, person_id: u.person_id}

  defp device_snapshot(%Device{} = d),
    do: %{id: d.id, user_id: d.user_id, platform: d.platform, revoked_at: d.revoked_at}

  defp assignment_snapshot(%WardenAssignment{} = a),
    do: %{
      id: a.id,
      user_id: a.user_id,
      zone_id: a.zone_id,
      area_id: a.area_id,
      starts_at: a.starts_at,
      ends_at: a.ends_at
    }
end
