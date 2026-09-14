defmodule Salvorion.Reporting.ReportRun do
  @moduledoc """
  One generated report for one closed Activation (FR-REP-01 to
  FR-REP-06). Delivery to individual recipients is tracked
  separately in ReportDelivery, since one recipient can fail
  while others succeed.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending generated delivered failed)

  schema "report_runs" do
    field :generated_at, :utc_datetime_usec
    field :pdf_path, :string
    field :status, :string, default: "pending"

    belongs_to :activation, Salvorion.Activations.Activation

    has_many :deliveries, Salvorion.Reporting.ReportDelivery

    many_to_many :recipients, Salvorion.Reporting.ReportRecipient,
      join_through: "report_deliveries",
      join_keys: [report_run_id: :id, report_recipient_id: :id]

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(report_run, attrs) do
    report_run
    |> cast(attrs, [:activation_id, :generated_at, :pdf_path, :status])
    |> validate_required([:activation_id])
    |> validate_inclusion(:status, unquote(@statuses))
    |> foreign_key_constraint(:activation_id)
  end
end
