defmodule Salvorion.Roster.Workers.PurgeVisitorsWorkerTest do
  use Salvorion.DataCase, async: true
  use Oban.Testing, repo: Salvorion.Repo

  alias Salvorion.Roster
  alias Salvorion.Roster.Workers.PurgeVisitorsWorker

  test "config/config.exs schedules it daily at 02:00 UTC on :maintenance" do
    plugins = Application.fetch_env!(:salvorion, Oban)[:plugins]
    {Oban.Plugins.Cron, cron_opts} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

    assert {"0 2 * * *", PurgeVisitorsWorker} in cron_opts[:crontab]
  end

  test "the configured cron string itself actually parses to 02:00 daily" do
    plugins = Application.fetch_env!(:salvorion, Oban)[:plugins]
    {Oban.Plugins.Cron, cron_opts} = Enum.find(plugins, &match?({Oban.Plugins.Cron, _}, &1))

    {cron_string, PurgeVisitorsWorker} =
      Enum.find(cron_opts[:crontab], &match?({_cron, PurgeVisitorsWorker}, &1))

    # Oban.Plugins.Cron is a deprecated delegate to Oban.Cron in this
    # version; the parser (Oban.Cron.Expression) is the same either way.
    # Parsing the *configured string*, not a copy-pasted "0 2 * * *"
    # literal, means a typo in config.exs fails this test rather than
    # silently never firing at 02:00.
    parsed = Oban.Cron.Expression.parse!(cron_string)

    assert parsed.minutes == MapSet.new([0])
    assert parsed.hours == MapSet.new([2])
    assert parsed.days == MapSet.new(1..31)
    assert parsed.months == MapSet.new(1..12)
    assert parsed.weekdays == MapSet.new(0..6)

    assert Oban.Cron.Expression.now?(parsed, ~U[2026-01-15 02:00:00Z])
    refute Oban.Cron.Expression.now?(parsed, ~U[2026-01-15 02:01:00Z])
    refute Oban.Cron.Expression.now?(parsed, ~U[2026-01-15 14:00:00Z])
  end

  test "Oban is in :manual testing mode: inserting the job does not run it" do
    assert Application.fetch_env!(:salvorion, Oban)[:testing] == :manual

    {:ok, _job} = PurgeVisitorsWorker.new(%{}) |> Oban.insert()
    assert_enqueued(worker: PurgeVisitorsWorker, queue: :maintenance)
  end

  test "perform/1 calls purge_expired_visitors/1 and returns :ok" do
    {:ok, _person, nil} =
      Roster.register_visitor(%{
        first_name: "Old",
        last_name: "Visitor",
        visitor_host: "Someone",
        visitor_expires_at: Date.add(Date.utc_today(), -100)
      })

    assert :ok = perform_job(PurgeVisitorsWorker, %{})

    assert [%{first_name: "Visitor", last_name: "(purged)"}] =
             Roster.list_visitors(active_on: ~D[0001-01-01])
             |> Enum.filter(&(&1.first_name == "Visitor"))
  end

  test "the args shape Cron's own tick sends (an empty map) is accepted" do
    # Oban.Cron.build_changeset/4 (private, deps/oban/lib/oban/cron.ex) does
    # `{args, opts} = Keyword.pop(opts, :args, %{})` — our crontab entry is a
    # bare {cron, worker} 2-tuple with no :args option, so a real tick calls
    # exactly `PurgeVisitorsWorker.new(%{}, opts)`. PurgeVisitorsWorker
    # defines no args schema (no `use Oban.Worker, ... , args_schema: ...`),
    # so the relevant check is that new/1 builds a valid, insertable
    # changeset and perform/1 does not pattern-match-fail on it.
    changeset = PurgeVisitorsWorker.new(%{})
    assert changeset.valid?

    assert {:ok, job} = Oban.insert(changeset)
    assert job.args == %{}
    assert job.worker == "Salvorion.Roster.Workers.PurgeVisitorsWorker"

    # perform/1 only matches on %Oban.Job{}, not on the shape of :args, so
    # the empty map Cron sends can never trip a pattern-match failure here.
    assert :ok = PurgeVisitorsWorker.perform(%Oban.Job{args: %{}})
  end

  test "unique: [period: 86_400] means inserting the job twice in one day yields one job" do
    assert PurgeVisitorsWorker.__opts__()[:unique][:period] == 86_400

    {:ok, job1} = PurgeVisitorsWorker.new(%{}) |> Oban.insert()
    {:ok, job2} = PurgeVisitorsWorker.new(%{}) |> Oban.insert()

    assert job1.id == job2.id

    import Ecto.Query

    assert Repo.aggregate(
             from(j in Oban.Job,
               where: j.worker == "Salvorion.Roster.Workers.PurgeVisitorsWorker"
             ),
             :count
           ) == 1
  end
end
