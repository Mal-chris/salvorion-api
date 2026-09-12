defmodule Salvorion.Reporting.ReportRecipient do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "report_recipients" do
    field :name, :string
    field :email, :string
    field :role, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(recipient, attrs) do
    recipient
    |> cast(attrs, [:name, :email, :role, :active])
    |> validate_required([:name, :email])
    |> validate_format(:email, ~r/@/)
    |> unique_constraint(:email)
  end
end
