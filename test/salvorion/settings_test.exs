defmodule Salvorion.SettingsTest do
  use Salvorion.DataCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.{Audit, Settings}

  test "get_setting/2 returns the caller's default when no row exists" do
    assert Settings.get_setting("student_accountability_rule", "signed_in_only") ==
             "signed_in_only"
  end

  test "put_setting/3 creates, replaces, and audits with before/after" do
    admin = user_fixture()

    assert {:ok, _} = Settings.put_setting("visitor_retention_days", 90, actor: admin)
    assert Settings.get_setting("visitor_retention_days", 30) == 90

    assert {:ok, _} = Settings.put_setting("visitor_retention_days", 120, actor: admin)
    assert Settings.get_setting("visitor_retention_days", 30) == 120

    assert [second, first] = Audit.list_audit_logs(entity_type: "setting")
    assert first.action == "setting.updated"
    assert first.actor_user_id == admin.id
    assert first.before == nil
    assert first.after == %{"key" => "visitor_retention_days", "value" => 90}
    assert second.before == %{"key" => "visitor_retention_days", "value" => 90}
    assert second.after["value"] == 120
  end
end
