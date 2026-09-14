defmodule SalvorionWeb.UserSocketTest do
  # async: false, matching SalvorionWeb.ActivationChannelTest — no channel
  # process is actually joined here, but keeping every channel-layer test
  # file on the same sandbox mode avoids a footgun if a later test here
  # ever does join one.
  use SalvorionWeb.ChannelCase, async: false

  import Salvorion.AccountsFixtures

  alias Salvorion.Accounts
  alias Salvorion.Accounts.Guardian
  alias SalvorionWeb.UserSocket

  describe "connect/3" do
    test "a valid token succeeds and assigns current_user_id, current_role, current_device_id" do
      user = user_fixture(%{role: "warden"})
      device = device_fixture(user)
      {:ok, tokens} = Accounts.issue_tokens(user, device_id: device.id)

      assert {:ok, socket} = connect(UserSocket, %{"token" => tokens.access_token})
      assert socket.assigns.current_user_id == user.id
      assert socket.assigns.current_role == "warden"
      assert socket.assigns.current_device_id == device.id
      assert %{"sub" => _} = socket.assigns.token_claims
      assert UserSocket.id(socket) == "user_socket:#{user.id}"
    end

    test "no device_id claim leaves current_device_id nil" do
      user = user_fixture(%{role: "admin"})
      {:ok, tokens} = Accounts.issue_tokens(user)

      assert {:ok, socket} = connect(UserSocket, %{"token" => tokens.access_token})
      assert socket.assigns.current_device_id == nil
    end

    test "an expired token is refused" do
      user = user_fixture(%{role: "warden"})

      {:ok, token, _claims} =
        Guardian.encode_and_sign(user, %{}, token_type: "access", ttl: {-1, :second})

      assert :error = connect(UserSocket, %{"token" => token})
    end

    test "a revoked device's token is refused" do
      user = user_fixture(%{role: "warden"})
      device = device_fixture(user)
      {:ok, tokens} = Accounts.issue_tokens(user, device_id: device.id)
      {:ok, _device} = Accounts.revoke_device(device)

      assert :error = connect(UserSocket, %{"token" => tokens.access_token})
    end

    test "a missing token is refused" do
      assert :error = connect(UserSocket, %{})
    end
  end
end
