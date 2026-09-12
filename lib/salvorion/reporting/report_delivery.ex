defmodule Salvorion.Reporting.ReportDelivery do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending sent failed)

  schema "report_deliveries" do
    field :delivered_at, :utc_datetime_usec
    field :delivery_status, :string, default: "pending"

    belongs_to :report_run, Salvorion.Reporting.ReportRun
    belongs_to :report_recipient, Salvorion.Reporting.ReportRecipient

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(delivery, attrs) do
    delivery
    |> cast(attrs, [:report_run_id, :report_recipient_id, :delivered_at, :delivery_status])
    |> validate_required([:report_run_id, :report_recipient_id])
    |> validate_inclusion(:delivery_status, unquote(@statuses))
    |> unique_constraint([:report_run_id, :report_recipient_id])
    |> foreign_key_constraint(:report_run_id)
    |> foreign_key_constraint(:report_recipient_id)
  end
end
