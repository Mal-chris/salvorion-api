defmodule Salvorion.Roster.Workers.PurgeVisitorsWorker do
  @moduledoc """
  Daily visitor-retention purge (FR-VIS-04; Document 10, section 6;
  NFR-PRIV-01), scheduled via `Oban.Plugins.Cron` at 02:00 UTC
  (`config/config.exs`). Calls `Salvorion.Roster.purge_expired_visitors/1`
  with no actor: this is a system action, audited as such.

  `unique: [period: 86_400]` (24h) means Oban will not enqueue a second
  copy of this job while one inserted in the last day is still
  available/scheduled/executing, so the cron trigger cannot double up a
  day's run even if the app restarts and Cron re-evaluates its schedule.
  """
  use Oban.Worker, queue: :maintenance, unique: [period: 86_400]

  alias Salvorion.Roster

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {:ok, _count} = Roster.purge_expired_visitors()
    :ok
  end
end
