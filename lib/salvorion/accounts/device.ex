defmodule Salvorion.Accounts.Device do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @platforms ~w(android ios web)

  schema "devices" do
    field :platform, :string
    field :last_sync_at, :utc_datetime_usec
    # Set to revoke a lost or decommissioned device without disabling the user.
    field :revoked_at, :utc_datetime_usec

    belongs_to :user, Salvorion.Accounts.User

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:user_id, :platform, :last_sync_at, :revoked_at])
    |> validate_required([:user_id, :platform])
    |> validate_inclusion(:platform, unquote(@platforms))
    |> foreign_key_constraint(:user_id)
  end
end
