defmodule Salvorion.AccountsTest do
  use Salvorion.DataCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Accounts
  alias Salvorion.Audit

  describe "register_user/2" do
    test "creates a user with a hashed password and audits it" do
      admin = user_fixture()
      email = unique_email()

      assert {:ok, user} =
               Accounts.register_user(%{email: email, password: "s3cret-pass", role: "warden"},
                 actor: admin
               )

      assert user.email == email
      assert user.role == "warden"
      assert user.active
      assert user.password_hash != "s3cret-pass"
      assert Argon2.verify_pass("s3cret-pass", user.password_hash)

      assert [log] = Audit.list_audit_logs(entity_type: "user", entity_id: user.id)
      assert log.action == "user.registered"
      assert log.actor_user_id == admin.id
      assert log.before == nil
      assert log.after["email"] == email
      refute Map.has_key?(log.after, "password_hash")
    end

    test "rejects an invalid role and a missing password" do
      assert {:error, changeset} = Accounts.register_user(%{email: unique_email(), role: "root"})
      assert %{role: ["is invalid"], password: ["can't be blank"]} = errors_on(changeset)
    end

    test "enforces unique email" do
      user = user_fixture()

      assert {:error, changeset} =
               Accounts.register_user(%{
                 email: user.email,
                 password: valid_password(),
                 role: "admin"
               })

      assert %{email: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "authenticate_user/2" do
    test "returns the user for correct credentials" do
      user = user_fixture()
      assert {:ok, %{id: id}} = Accounts.authenticate_user(user.email, valid_password())
      assert id == user.id
    end

    test "returns the same error for unknown email, wrong password and deactivated user" do
      user = user_fixture()

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user("nobody@x.test", "whatever")

      assert {:error, :invalid_credentials} = Accounts.authenticate_user(user.email, "wrong")

      {:ok, _} = Accounts.deactivate_user(user, actor: user)

      assert {:error, :invalid_credentials} =
               Accounts.authenticate_user(user.email, valid_password())
    end
  end

  describe "user management" do
    test "update_user_role/3 changes the role and audits before/after" do
      admin = user_fixture()
      user = user_fixture(%{role: "warden"})

      assert {:ok, updated} = Accounts.update_user_role(user, "osh_officer", actor: admin)
      assert updated.role == "osh_officer"

      assert [log] = Audit.list_audit_logs(action: "user.role_changed", entity_id: user.id)
      assert log.before["role"] == "warden"
      assert log.after["role"] == "osh_officer"
      assert log.actor_user_id == admin.id
    end

    test "deactivate_user/2 keeps the row and sets active: false" do
      admin = user_fixture()
      user = user_fixture()

      assert {:ok, deactivated} = Accounts.deactivate_user(user, actor: admin)
      refute deactivated.active
      assert Accounts.get_user!(user.id).id == user.id

      assert [%{action: "user.deactivated"}] =
               Audit.list_audit_logs(entity_id: user.id, action: "user.deactivated")
    end

    test "list_users/0 returns every user" do
      a = user_fixture()
      b = user_fixture()
      ids = Accounts.list_users() |> Enum.map(& &1.id)
      assert a.id in ids and b.id in ids
    end
  end

  describe "devices" do
    test "register_device/3 and revoke_device/2 set revoked_at without deleting" do
      user = user_fixture()

      assert {:ok, device} = Accounts.register_device(user, %{platform: "ios"}, actor: user)
      assert device.user_id == user.id
      refute Accounts.device_revoked?(device.id)

      assert {:ok, revoked} = Accounts.revoke_device(device, actor: user)
      assert %DateTime{} = revoked.revoked_at
      assert Accounts.device_revoked?(device.id)
      assert Accounts.get_device(device.id)

      # idempotent
      assert {:ok, ^revoked} = Accounts.revoke_device(revoked, actor: user)

      actions =
        Audit.list_audit_logs(entity_type: "device", entity_id: device.id)
        |> Enum.map(& &1.action)

      assert Enum.sort(actions) == ["device.registered", "device.revoked"]
    end

    test "rejects an unknown platform" do
      user = user_fixture()
      assert {:error, changeset} = Accounts.register_device(user, %{platform: "blackberry"})
      assert %{platform: ["is invalid"]} = errors_on(changeset)
    end

    test "device_revoked?/1 is true for unknown or malformed ids" do
      assert Accounts.device_revoked?(Ecto.UUID.generate())
      assert Accounts.device_revoked?("not-a-uuid")
    end
  end

  describe "assign_warden/4" do
    test "creates an assignment for a zone and audits it" do
      admin = user_fixture()
      warden = user_fixture(%{role: "warden"})
      zone = zone_fixture()

      assert {:ok, assignment} =
               Accounts.assign_warden(
                 warden.id,
                 {:zone, zone.id},
                 {~D[2026-09-01], ~D[2026-12-31]},
                 actor: admin
               )

      assert assignment.zone_id == zone.id
      assert assignment.area_id == nil

      assert [%{action: "warden_assignment.created"}] =
               Audit.list_audit_logs(entity_id: assignment.id)
    end

    test "accepts a Date.Range and an open-ended range" do
      warden = user_fixture(%{role: "warden"})
      zone = zone_fixture()

      assert {:ok, _} =
               Accounts.assign_warden(
                 warden.id,
                 {:zone, zone.id},
                 Date.range(~D[2026-01-01], ~D[2026-01-31])
               )

      assert {:ok, a} = Accounts.assign_warden(warden.id, {:zone, zone.id}, {~D[2026-01-01], nil})
      assert a.ends_at == nil
    end

    test "rejects a missing scope before hitting the database" do
      warden = user_fixture(%{role: "warden"})

      assert {:error, changeset} = Accounts.assign_warden(warden.id, nil, {~D[2026-01-01], nil})
      assert %{zone_id: ["must set either a zone or an area"]} = errors_on(changeset)
    end

    test "rejects an end date before the start date" do
      warden = user_fixture(%{role: "warden"})
      zone = zone_fixture()

      assert {:error, changeset} =
               Accounts.assign_warden(
                 warden.id,
                 {:zone, zone.id},
                 {~D[2026-02-01], ~D[2026-01-01]}
               )

      assert %{ends_at: ["must be on or after starts_at"]} = errors_on(changeset)
    end
  end

  describe "tokens" do
    test "issue_tokens/2 returns RS256 access (15 min) and refresh (30 days) tokens with role and kid" do
      user = user_fixture(%{role: "osh_officer"})
      assert {:ok, tokens} = Accounts.issue_tokens(user)
      assert tokens.expires_in == 900

      %{claims: claims} = Accounts.Guardian.peek(tokens.access_token)
      [raw_header, _, _] = String.split(tokens.access_token, ".")
      headers = raw_header |> Base.url_decode64!(padding: false) |> Jason.decode!()
      assert headers["alg"] == "RS256"
      assert headers["kid"] == Accounts.Keys.kid()
      assert claims["sub"] == user.id
      assert claims["role"] == "osh_officer"
      assert claims["typ"] == "access"
      assert claims["exp"] - claims["iat"] == 15 * 60
      assert "powersync" in claims["aud"]

      %{claims: refresh_claims} = Accounts.Guardian.peek(tokens.refresh_token)
      assert refresh_claims["typ"] == "refresh"
      assert refresh_claims["exp"] - refresh_claims["iat"] == 30 * 24 * 60 * 60
    end

    test "refresh_tokens/1 rotates tokens and refuses access tokens or deactivated users" do
      user = user_fixture()
      {:ok, tokens} = Accounts.issue_tokens(user)

      assert {:ok, %{access_token: _}} = Accounts.refresh_tokens(tokens.refresh_token)
      assert {:error, :invalid_token} = Accounts.refresh_tokens(tokens.access_token)

      {:ok, _} = Accounts.deactivate_user(user, actor: user)
      assert {:error, :invalid_token} = Accounts.refresh_tokens(tokens.refresh_token)
    end
  end
end
