defmodule Salvorion.Audit.AuditLog do
  @moduledoc """
  Immutable record of who did what, to what, and when (FR-AUD-01
  to FR-AUD-03). `actor_user_id` is nullable to allow system jobs
  (the visitor purge, an automated report retry) to still produce
  an audit trail. There is deliberately no update_changeset: audit
  rows are inserted only, and no context function should ever call
  Repo.update or Repo.delete against this schema.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "audit_logs" do
    field :action, :string
    field :entity_type, :string
    field :entity_id, :binary_id
    field :before, :map
    field :after, :map

    belongs_to :actor, Salvorion.Accounts.User, foreign_key: :actor_user_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(audit_log, attrs) do
    audit_log
    |> cast(attrs, [:actor_user_id, :action, :entity_type, :entity_id, :before, :after])
    |> validate_required([:action, :entity_type])
    |> foreign_key_constraint(:actor_user_id)
  end
end
