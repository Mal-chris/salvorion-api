defmodule SalvorionWeb.DeviceControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  describe "POST /api/devices" do
    test "any authenticated role can register their own device", %{conn: conn} do
      for role <- SalvorionWeb.RBAC.roles() do
        user = user_fixture(%{role: role})
        conn = conn |> authed(user) |> post(~p"/api/devices", %{platform: "android"})

        assert %{"data" => %{"user_id" => user_id, "platform" => "android"}} =
                 json_response(conn, 201)

        assert user_id == user.id
      end
    end

    test "no token gets 401", %{conn: conn} do
      assert json_response(post(conn, ~p"/api/devices", %{platform: "android"}), 401)
    end
  end

  describe "POST /api/devices/:id/revoke" do
    test "the device's own user can revoke it", %{conn: conn} do
      user = user_fixture()
      device = device_fixture(user)

      conn = conn |> authed(user) |> post(~p"/api/devices/#{device.id}/revoke")
      assert %{"data" => %{"revoked_at" => revoked_at}} = json_response(conn, 200)
      refute is_nil(revoked_at)
    end

    test "admin can revoke someone else's device", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      other = user_fixture()
      device = device_fixture(other)

      conn = conn |> authed(admin) |> post(~p"/api/devices/#{device.id}/revoke")
      assert %{"data" => %{"revoked_at" => revoked_at}} = json_response(conn, 200)
      refute is_nil(revoked_at)
    end

    test "a different, non-admin user gets 403 — cannot revoke someone else's device", %{
      conn: conn
    } do
      owner = user_fixture()
      other = user_fixture(%{role: "warden"})
      device = device_fixture(owner)

      conn = conn |> authed(other) |> post(~p"/api/devices/#{device.id}/revoke")
      assert json_response(conn, 403)
    end
  end
end
