defmodule Salvorion.ActivationsTest do
  # async: false — start_activation/2 serialises on a single fixed
  # advisory-lock key, so concurrent async tests calling it would
  # contend with each other for no reason.
  use Salvorion.DataCase, async: false

  import Salvorion.AccountsFixtures

  alias Salvorion.Activations
  alias Salvorion.Activations.Activation
  alias Salvorion.Audit

  # ---------------------------------------------------------------------------
  # schedule_activation/2
  # ---------------------------------------------------------------------------

  describe "schedule_activation/2" do
    test "creates a scheduled campus activation and audits it" do
      officer = user_fixture()

      assert {:ok, activation} =
               Activations.schedule_activation(
                 %{activation_type: "drill", started_at: DateTime.utc_now()},
                 actor: officer
               )

      assert activation.status == "scheduled"
      assert activation.scope == "campus"
      assert activation.started_by_id == officer.id

      assert [log] = Audit.list_audit_logs(entity_type: "activation", entity_id: activation.id)
      assert log.action == "activation.scheduled"
      assert log.actor_user_id == officer.id
      assert log.after["activation_type"] == "drill"
      assert log.after["scope"] == "campus"
    end

    test "requires an actor (started_by_id can't be blank)" do
      assert {:error, changeset} =
               Activations.schedule_activation(%{
                 activation_type: "drill",
                 started_at: DateTime.utc_now()
               })

      assert %{started_by_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "zones scope requires at least one existing zone_id" do
      officer = user_fixture()

      assert {:error, changeset} =
               Activations.schedule_activation(
                 %{activation_type: "drill", scope: "zones", started_at: DateTime.utc_now()},
                 actor: officer
               )

      assert %{zone_ids: ["can't be blank"]} = errors_on(changeset)

      assert {:error, changeset} =
               Activations.schedule_activation(
                 %{
                   activation_type: "drill",
                   scope: "zones",
                   zone_ids: [Ecto.UUID.generate()],
                   started_at: DateTime.utc_now()
                 },
                 actor: officer
               )

      assert %{zone_ids: [msg]} = errors_on(changeset)
      assert msg =~ "does not exist"
    end

    test "stores the given zones and does not touch the overlap guard" do
      officer = user_fixture()
      zone = zone_fixture()

      assert {:ok, activation} =
               Activations.schedule_activation(
                 %{
                   activation_type: "drill",
                   scope: "zones",
                   zone_ids: [zone.id],
                   started_at: DateTime.utc_now()
                 },
                 actor: officer
               )

      assert activation.status == "scheduled"
      assert Activations.get_active_activation_for_zone(zone.id) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # start_activation/2 — direct creation
  # ---------------------------------------------------------------------------

  describe "start_activation/2 with attrs (direct)" do
    test "creates an active campus activation immediately and audits it" do
      officer = user_fixture()

      assert {:ok, activation} =
               Activations.start_activation(%{activation_type: "real"}, actor: officer)

      assert activation.status == "active"
      assert activation.scope == "campus"
      assert activation.started_by_id == officer.id

      assert [log] =
               Audit.list_audit_logs(
                 entity_type: "activation",
                 entity_id: activation.id,
                 action: "activation.started"
               )

      assert log.actor_user_id == officer.id
      assert log.after["status"] == "active"

      # starting also materialises expected presence in the same transaction
      assert [_] =
               Audit.list_audit_logs(
                 entity_id: activation.id,
                 action: "accountability.expectations_initialised"
               )
    end

    test "zones scope inserts activation_zones and is found by get_active_activation_for_zone/1" do
      officer = user_fixture()
      zone = zone_fixture()

      assert {:ok, activation} =
               Activations.start_activation(
                 %{activation_type: "drill", scope: "zones", zone_ids: [zone.id]},
                 actor: officer
               )

      assert Activations.get_active_activation_for_zone(zone.id).id == activation.id
    end

    test "rejects a malformed zone id as a validation error, not a DB exception" do
      officer = user_fixture()

      assert {:error, changeset} =
               Activations.start_activation(
                 %{activation_type: "drill", scope: "zones", zone_ids: ["not-a-uuid"]},
                 actor: officer
               )

      assert %{zone_ids: [msg]} = errors_on(changeset)
      assert msg =~ "does not exist"
      assert Repo.aggregate(Activation, :count) == 0
    end

    test "a forged started_by_id and a backdated started_at in attrs are both ignored" do
      officer = user_fixture()
      someone_else = user_fixture()
      backdated = DateTime.add(DateTime.utc_now(), -7 * 24 * 60 * 60, :second)

      before_call = DateTime.utc_now()

      assert {:ok, activation} =
               Activations.start_activation(
                 %{
                   activation_type: "real",
                   started_by_id: someone_else.id,
                   started_at: backdated
                 },
                 actor: officer
               )

      after_call = DateTime.utc_now()

      # attributed to the real caller, never the forged id
      assert activation.started_by_id == officer.id
      refute activation.started_by_id == someone_else.id

      # started_at is the real moment of the call, never the backdated value
      assert DateTime.compare(activation.started_at, before_call) in [:gt, :eq]
      assert DateTime.compare(activation.started_at, after_call) in [:lt, :eq]
      refute DateTime.compare(activation.started_at, backdated) == :eq

      assert [log] =
               Audit.list_audit_logs(
                 entity_type: "activation",
                 entity_id: activation.id,
                 action: "activation.started"
               )

      assert log.actor_user_id == officer.id
    end
  end

  # ---------------------------------------------------------------------------
  # start_activation/2 — transitioning a scheduled activation
  # ---------------------------------------------------------------------------

  describe "start_activation/2 on an existing scheduled activation" do
    test "transitions scheduled -> active, reusing its scheduled zones" do
      officer = user_fixture()
      zone = zone_fixture()

      {:ok, scheduled} =
        Activations.schedule_activation(
          %{
            activation_type: "drill",
            scope: "zones",
            zone_ids: [zone.id],
            started_at: DateTime.utc_now()
          },
          actor: officer
        )

      assert scheduled.status == "scheduled"

      assert {:ok, started} = Activations.start_activation(scheduled, actor: officer)
      assert started.id == scheduled.id
      assert started.status == "active"
      assert Activations.get_active_activation_for_zone(zone.id).id == started.id

      assert [start_log] =
               Audit.list_audit_logs(entity_id: started.id, action: "activation.started")

      assert [_] = Audit.list_audit_logs(entity_id: started.id, action: "activation.scheduled")
      assert start_log.before["status"] == "scheduled"
      assert start_log.after["status"] == "active"
    end

    test "rejects starting an activation that is not scheduled" do
      officer = user_fixture()
      {:ok, active} = Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      assert {:error, {:invalid_state, message}} =
               Activations.start_activation(active, actor: officer)

      assert message =~ "status is active"
    end
  end

  # ---------------------------------------------------------------------------
  # The zone-overlap guard (FR-ACT-05)
  # ---------------------------------------------------------------------------

  describe "zone-overlap guard" do
    test "a campus activation conflicts with any other active activation" do
      officer = user_fixture()
      zone = zone_fixture()

      {:ok, campus} = Activations.start_activation(%{activation_type: "real"}, actor: officer)

      assert {:error, {:zone_conflict, message}} =
               Activations.start_activation(
                 %{activation_type: "drill", scope: "zones", zone_ids: [zone.id]},
                 actor: officer
               )

      assert message =~ campus.id
      assert message =~ "scope: campus"

      assert {:ok, closed} = Activations.close_activation(campus, actor: officer)
      assert closed.status == "closed"

      assert {:ok, second} =
               Activations.start_activation(
                 %{activation_type: "drill", scope: "zones", zone_ids: [zone.id]},
                 actor: officer
               )

      assert second.status == "active"
    end

    test "non-overlapping zone-scope activations both start; a repeat on the same zone is rejected" do
      officer = user_fixture()
      zone_a = zone_fixture()
      zone_b = zone_fixture()

      assert {:ok, first} =
               Activations.start_activation(
                 %{activation_type: "drill", scope: "zones", zone_ids: [zone_a.id]},
                 actor: officer
               )

      assert {:ok, second} =
               Activations.start_activation(
                 %{activation_type: "drill", scope: "zones", zone_ids: [zone_b.id]},
                 actor: officer
               )

      assert first.status == "active"
      assert second.status == "active"

      assert {:error, {:zone_conflict, message}} =
               Activations.start_activation(
                 %{activation_type: "drill", scope: "zones", zone_ids: [zone_a.id]},
                 actor: officer
               )

      assert message =~ first.id
      refute message =~ second.id
    end
  end

  # ---------------------------------------------------------------------------
  # close_activation/2
  # ---------------------------------------------------------------------------

  describe "close_activation/2" do
    test "closes an active activation and audits it" do
      officer = user_fixture()

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      assert {:ok, closed} = Activations.close_activation(activation, actor: officer)
      assert closed.status == "closed"
      assert closed.closed_by_id == officer.id

      assert [close_log] =
               Audit.list_audit_logs(entity_id: activation.id, action: "activation.closed")

      assert close_log.actor_user_id == officer.id
    end

    test "rejects closing an activation that is not active, with a clear error" do
      officer = user_fixture()

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      {:ok, closed} = Activations.close_activation(activation, actor: officer)

      assert {:error, changeset} = Activations.close_activation(closed, actor: officer)
      assert %{status: ["activation must be active to close"]} = errors_on(changeset)

      # not a silent no-op: the row is untouched
      assert Activations.get_activation!(closed.id).status == "closed"
    end

    test "requires an actor (closed_by_id can't be blank)" do
      officer = user_fixture()

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      assert {:error, changeset} = Activations.close_activation(activation)
      assert %{closed_by_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # mark_activation_reported/1
  # ---------------------------------------------------------------------------

  describe "mark_activation_reported/1" do
    test "transitions closed -> reported and audits with no actor" do
      officer = user_fixture()

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      {:ok, closed} = Activations.close_activation(activation, actor: officer)

      assert {:ok, reported} = Activations.mark_activation_reported(closed)
      assert reported.status == "reported"

      assert [report_log] =
               Audit.list_audit_logs(entity_id: reported.id, action: "activation.reported")

      assert report_log.actor_user_id == nil
    end

    test "rejects marking a non-closed activation as reported" do
      officer = user_fixture()

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      assert {:error, changeset} = Activations.mark_activation_reported(activation)

      assert %{status: ["activation must be closed before it can be marked reported"]} =
               errors_on(changeset)
    end
  end

  # ---------------------------------------------------------------------------
  # Full lifecycle
  # ---------------------------------------------------------------------------

  test "full lifecycle: scheduled -> active -> closed -> reported" do
    officer = user_fixture()

    {:ok, scheduled} =
      Activations.schedule_activation(
        %{activation_type: "drill", started_at: DateTime.utc_now()},
        actor: officer
      )

    assert scheduled.status == "scheduled"

    {:ok, active} = Activations.start_activation(scheduled, actor: officer)
    assert active.status == "active"

    {:ok, closed} = Activations.close_activation(active, actor: officer)
    assert closed.status == "closed"

    {:ok, reported} = Activations.mark_activation_reported(closed)
    assert reported.status == "reported"
  end

  # ---------------------------------------------------------------------------
  # list_activations/1
  # ---------------------------------------------------------------------------

  describe "list_activations/1" do
    test "filters by status and activation_type" do
      officer = user_fixture()
      {:ok, drill} = Activations.start_activation(%{activation_type: "drill"}, actor: officer)
      {:ok, closed_drill} = Activations.close_activation(drill, actor: officer)

      zone = zone_fixture()

      {:ok, real} =
        Activations.start_activation(
          %{activation_type: "real", scope: "zones", zone_ids: [zone.id]},
          actor: officer
        )

      assert Activations.list_activations(status: "closed") |> Enum.map(& &1.id) == [
               closed_drill.id
             ]

      ids = Activations.list_activations(activation_type: "real") |> Enum.map(& &1.id)
      assert real.id in ids
      refute drill.id in ids
    end
  end

  # ---------------------------------------------------------------------------
  # Concurrency: the advisory lock actually guards the overlap check.
  #
  # This test needs two genuinely separate database connections/sessions
  # (a pg_advisory_xact_lock is reentrant within one session, so running
  # both calls through the shared sandbox connection would prove nothing).
  # It temporarily switches the Repo to :auto sandbox mode, runs two real
  # concurrent connections against the test database, then cleans up the
  # rows it committed and restores :manual mode. Tagged `:concurrency`
  # for `mix test --only concurrency`, but not excluded by default: it
  # runs in ExUnit's sync phase (this module is async: false), which
  # always completes after every async module has already finished, so
  # the global sandbox-mode switch cannot land mid-flight of another test.
  # ---------------------------------------------------------------------------

  @tag :concurrency
  test "only one of two concurrent start_activation calls for the same zone wins" do
    Ecto.Adapters.SQL.Sandbox.mode(Repo, :auto)

    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.mode(Repo, :manual) end)

    officer = user_fixture()
    zone = zone_fixture()

    try do
      results =
        [1, 2]
        |> Enum.map(fn _ ->
          Task.async(fn ->
            Activations.start_activation(
              %{activation_type: "drill", scope: "zones", zone_ids: [zone.id]},
              actor: officer
            )
          end)
        end)
        |> Enum.map(&Task.await(&1, 5_000))

      oks = Enum.filter(results, &match?({:ok, _}, &1))
      errors = Enum.filter(results, &match?({:error, {:zone_conflict, _}}, &1))

      assert length(oks) == 1
      assert length(errors) == 1
    after
      # `results` is bound inside `try do`, not guaranteed visible here if
      # an exception occurred, so re-derive what to clean up from officer.id
      # instead (unique to this test via user_fixture's unique email).
      activation_ids =
        Repo.all(from a in Activation, where: a.started_by_id == ^officer.id, select: a.id)

      # activation_zones cascades from the activations delete (on_delete:
      # :delete_all); started_by_id is on_delete: :restrict, so the
      # activations must go before the user that started them.
      Repo.delete_all(from l in Salvorion.Audit.AuditLog, where: l.entity_id in ^activation_ids)
      Repo.delete_all(from a in Activation, where: a.id in ^activation_ids)
      Repo.delete_all(from z in Salvorion.Locations.Zone, where: z.id == ^zone.id)

      Repo.delete_all(
        from ap in Salvorion.Locations.AssemblyPoint, where: ap.id == ^zone.assembly_point_id
      )

      Repo.delete_all(from u in Salvorion.Accounts.User, where: u.id == ^officer.id)
    end
  end
end
