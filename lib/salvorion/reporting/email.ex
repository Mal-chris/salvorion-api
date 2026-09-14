defmodule Salvorion.Reporting.Email do
  @moduledoc """
  Builds the report email (Prompt 11, Task 6). Sending itself goes
  through `Salvorion.Mailer` (`Swoosh.Adapters.Local` in dev,
  `Swoosh.Adapters.Test` in test, `Swoosh.Adapters.AmazonSES` in prod
  only - `config/runtime.exs`), so this module never talks to a network
  service directly.
  """

  import Swoosh.Email

  alias Salvorion.Activations.Activation
  alias Salvorion.Reporting.{ReportRecipient, ReportRun}

  @doc """
  The email for one recipient: subject names the activation type and
  date (FR-REP-03's "automatically email the report"), body is a short
  summary, and the generated PDF (`run.pdf_path`) is attached.
  """
  @spec report_email(%ReportRecipient{}, %ReportRun{}, %Activation{}) :: Swoosh.Email.t()
  def report_email(%ReportRecipient{} = recipient, %ReportRun{} = run, %Activation{} = activation) do
    new()
    |> to({recipient.name, recipient.email})
    |> from({"Salvorion", Application.fetch_env!(:salvorion, :report_from_email)})
    |> subject(subject_line(activation))
    |> text_body(body_text(activation))
    |> attachment(
      Swoosh.Attachment.new(run.pdf_path,
        filename: "activation-report-#{activation.id}.pdf",
        content_type: "application/pdf"
      )
    )
  end

  defp subject_line(%Activation{} = activation) do
    kind = if activation.activation_type == "real", do: "Real emergency", else: "Drill"
    date = Calendar.strftime(activation.started_at, "%Y-%m-%d")
    "[Salvorion] #{kind} activation report - #{date}"
  end

  defp body_text(%Activation{} = activation) do
    """
    The activation report for the #{activation.activation_type} started on \
    #{activation.started_at} and closed on #{activation.closed_at} is attached as a PDF.

    This is an automated message from Salvorion.
    """
  end
end
