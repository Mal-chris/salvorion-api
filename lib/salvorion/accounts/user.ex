defmodule Salvorion.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @roles ~w(admin osh_officer warden report_viewer)

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true
    field :role, :string
    field :active, :boolean, default: true

    belongs_to :person, Salvorion.Roster.Person
    has_many :warden_assignments, Salvorion.Accounts.WardenAssignment
    has_many :devices, Salvorion.Accounts.Device

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :password, :role, :active, :person_id])
    |> validate_required([:email, :role])
    |> validate_inclusion(:role, unquote(@roles))
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
    |> foreign_key_constraint(:person_id)
    |> maybe_hash_password()
  end

  defp maybe_hash_password(changeset) do
    case get_change(changeset, :password) do
      nil -> changeset
      password -> put_change(changeset, :password_hash, Argon2.hash_pwd_salt(password))
    end
  end
end
