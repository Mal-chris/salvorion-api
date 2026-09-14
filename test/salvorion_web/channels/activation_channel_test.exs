defmodule SalvorionWeb.ActivationChannelTest do
  # async: false — joined channels run in their own process (distinct
  # from the test process), so the sandbox must be shared for that
  # process to see the same data the test set up (see ChannelCase).
  use SalvorionWeb.ChannelCase, async: false

  import Salvorion.AccountsFixtures
  import Salvorion.RosterFixtures

  alias Salvorion.{Accountability, Accounts, Activations}
  alias SalvorionWeb.UserSocket

  defp connect_and_join(user, activation, opts \\ []) do
    device_id = Keyword.get(opts, :device_id)
    {:ok, tokens} = Accounts.issue_tokens(user, device_id: device_id)
    {:ok, socket} = connect(UserSocket, %{"token" => tokens.access_token})
    subscribe_and_join(socket, "activation:#{activation.id}")
  end

  defp topology do
    zone5 = zone_fixture()
    zone8 = zone_fixture()
    %{zone5: zone5, zone8: zone8}
  end

  setup do
    %{zone5: zone5, zone8: zone8} = topology()

    starter = user_fixture(%{role: "osh_officer"})
    o1 = user_fixture(%{role: "osh_officer"})
    w5 = user_fixture(%{role: "warden"})
    w8 = user_fixture(%{role: "warden"})
    r1 = user_fixture(%{role: "report_viewer"})
    w_none = user_fixture(%{role: "warden"})

    {:ok, _} = Accounts.assign_warden(w5.id, {:zone, zone5.id}, {~D[2020-01-01], nil})
    {:ok, _} = Accounts.assign_warden(w8.id, {:zone, zone8.id}, {~D[2020-01-01], nil})

    {:ok, activation} =
      Activations.start_activation(%{activation_type: "drill"}, actor: starter)

    %{
      zone5: zone5,
      zone8: zone8,
      activation: activation,
      o1: o1,
      w5: w5,
      w8: w8,
      r1: r1,
      w_none: w_none
    }
  end

  describe "join/3" do
    test "every role may join; a nonexistent activation id fails with not_found", %{
      activation: activation,
      o1: o1,
      w5: w5,
      w8: w8,
      r1: r1
    } do
      assert {:ok, _reply, _socket} = connect_and_join(o1, activation)
      assert {:ok, _reply, _socket} = connect_and_join(w5, activation)
      assert {:ok, _reply, _socket} = connect_and_join(w8, activation)
      assert {:ok, _reply, _socket} = connect_and_join(r1, activation)

      {:ok, tokens} = Accounts.issue_tokens(o1)
      {:ok, socket} = connect(UserSocket, %{"token" => tokens.access_token})

      assert {:error, %{reason: "not_found"}} =
               subscribe_and_join(socket, "activation:#{Ecto.UUID.generate()}")
    end

    test "a warden with no effective assignment still joins, with an empty scope", %{
      activation: activation,
      w_none: w_none
    } do
      assert {:ok, _reply, socket} = connect_and_join(w_none, activation)
      assert socket.assigns.zone_ids == []
    end
  end

  # assert_push/refute_push check the CALLING process's own mailbox, and a
  # socket's pushes always land in whichever process called `connect/3`
  # for it (its `transport_pid`, fixed at connect time). Joining all five
  # roles from this one test process would put every push in one shared
  # mailbox, indistinguishable by origin — not rigorous enough to prove
  # "this specific role did/didn't receive this specific push". Instead
  # each role gets its own process (`Task.async`, `test_process: parent`
  # so `connect/3`'s ExUnit-supervisor lookup still resolves to the real
  # test process — see `Phoenix.ChannelTest.socket/4`'s own docs on this
  # option), and does its own assert_push/refute_push for its own socket.
  describe "person_status_updated and activation_changed" do
    test "person_status_updated reaches only in-scope sockets, never with zone_ids; activation_changed reaches every joined socket on close",
         %{activation: activation, zone5: zone5, o1: o1, w5: w5, w8: w8, r1: r1, w_none: w_none} do
      parent = self()
      person = person_fixture()
      roles = %{o1: o1, w5: w5, w8: w8, r1: r1, w_none: w_none}
      in_scope = [:o1, :r1, :w5]

      tasks =
        for {label, user} <- roles, into: %{} do
          task =
            Task.async(fn ->
              {:ok, tokens} = Accounts.issue_tokens(user)

              {:ok, socket} =
                connect(UserSocket, %{"token" => tokens.access_token}, test_process: parent)

              {:ok, _reply, _socket} = subscribe_and_join(socket, "activation:#{activation.id}")
              send(parent, {:joined, label})

              receive do
                :check_person_status_updated -> :ok
              end

              if label in in_scope do
                assert_push "person_status_updated", payload
                assert payload.person_id == person.id
                refute Map.has_key?(payload, :zone_ids)
              else
                refute_push "person_status_updated", _
              end

              send(parent, {:checked_person_status_updated, label})

              receive do
                :check_activation_changed -> :ok
              end

              assert_push "activation_changed", %{activation_id: aid, status: "closed"}
              assert aid == activation.id
              send(parent, {:checked_activation_changed, label})
            end)

          {label, task}
        end

      for _ <- roles, do: assert_receive({:joined, _label})

      {:ok, _event, _status} =
        Accountability.ingest_event(
          %{
            client_uuid: Ecto.UUID.generate(),
            activation_id: activation.id,
            person_id: person.id,
            kind: "scanned",
            status: "present",
            client_timestamp: DateTime.utc_now(),
            assembly_point_id: zone5.assembly_point_id
          },
          actor: o1
        )

      for {_label, task} <- tasks, do: send(task.pid, :check_person_status_updated)
      for _ <- roles, do: assert_receive({:checked_person_status_updated, _label}, 1000)

      {:ok, _closed} = Activations.close_activation(activation, actor: o1)

      for {_label, task} <- tasks, do: send(task.pid, :check_activation_changed)
      for _ <- roles, do: assert_receive({:checked_activation_changed, _label}, 1000)

      for {_label, task} <- tasks, do: Task.await(task, 1000)
    end
  end

  describe "Task 3: the revocation/expiry self-check" do
    test "a device revoked mid-connection: :check_revocation pushes session_revoked and terminates the channel",
         %{activation: activation, w5: w5} do
      device = device_fixture(w5)
      {:ok, tokens} = Accounts.issue_tokens(w5, device_id: device.id)
      {:ok, socket} = connect(UserSocket, %{"token" => tokens.access_token})
      {:ok, _reply, socket} = subscribe_and_join(socket, "activation:#{activation.id}")

      {:ok, _device} = Accounts.revoke_device(device)

      ref = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, :check_revocation)

      assert_push "session_revoked", %{}
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end

    test "a token whose own exp has already passed: :check_revocation pushes session_revoked and terminates the channel",
         %{activation: activation} do
      assigns = %{
        current_user_id: Ecto.UUID.generate(),
        current_role: "admin",
        current_device_id: nil,
        token_claims: %{"exp" => System.system_time(:second) - 1}
      }

      socket = socket(UserSocket, "user_socket:expired", assigns)
      {:ok, _reply, socket} = join(socket, "activation:#{activation.id}")

      ref = Process.monitor(socket.channel_pid)
      send(socket.channel_pid, :check_revocation)

      assert_push "session_revoked", %{}
      assert_receive {:DOWN, ^ref, :process, _pid, :normal}
    end
  end
end
