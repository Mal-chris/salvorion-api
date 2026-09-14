defmodule SalvorionWeb.SettingControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  alias Salvorion.Settings

  describe "GET /api/settings" do
    test "admin and osh_officer see every known key with its current value or documented default",
         %{conn: conn} do
      for role <- ["admin", "osh_officer"] do
        user = user_fixture(%{role: role})
        conn = conn |> authed(user) |> get(~p"/api/settings")
        assert %{"data" => data} = json_response(conn, 200)

        keys = Enum.map(data, & &1["key"])

        assert "student_accountability_rule" in keys
        assert "visitor_retention_days" in keys
        assert "id_barcode_parser" in keys
        assert "offline_login_grace_hours" in keys

        rule_row = Enum.find(data, &(&1["key"] == "student_accountability_rule"))
        assert rule_row["value"] == "signed_in_only"

        retention_row = Enum.find(data, &(&1["key"] == "visitor_retention_days"))
        assert retention_row["value"] == 90
      end
    end

    test "reflects a value already written via put_setting/3", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      {:ok, _} = Settings.put_setting("visitor_retention_days", 45, actor: admin)

      conn = conn |> authed(admin) |> get(~p"/api/settings")
      assert %{"data" => data} = json_response(conn, 200)
      row = Enum.find(data, &(&1["key"] == "visitor_retention_days"))
      assert row["value"] == 45
    end

    test "warden and report_viewer get 403", %{conn: conn} do
      for role <- ["warden", "report_viewer"] do
        user = user_fixture(%{role: role})
        assert json_response(conn |> authed(user) |> get(~p"/api/settings"), 403)
      end
    end
  end

  describe "PATCH /api/settings/:key" do
    test "a valid student_accountability_rule value is accepted and persisted, no warnings", %{
      conn: conn
    } do
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/settings/student_accountability_rule", %{value: "all_enrolled"})

      assert %{"data" => %{"key" => "student_accountability_rule", "value" => "all_enrolled"}} =
               json_response(conn, 200)

      assert json_response(conn, 200)["warnings"] == []

      assert Settings.get_setting("student_accountability_rule", "signed_in_only") ==
               "all_enrolled"
    end

    test "an invalid student_accountability_rule value is a 422 before it reaches the database",
         %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/settings/student_accountability_rule", %{value: "whatever_i_want"})

      assert %{"errors" => %{"value" => [_msg]}} = json_response(conn, 422)

      # nothing was written — the default still applies
      assert Settings.get_setting("student_accountability_rule", "signed_in_only") ==
               "signed_in_only"
    end

    test "\"timetable_expected\" is accepted and stored, but the response carries the not-yet-functional warning",
         %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/settings/student_accountability_rule", %{value: "timetable_expected"})

      assert %{"data" => %{"value" => "timetable_expected"}, "warnings" => [warning]} =
               json_response(conn, 200)

      assert warning =~ "not yet functional"

      assert Settings.get_setting("student_accountability_rule", "signed_in_only") ==
               "timetable_expected"
    end

    test "visitor_retention_days must be a positive integer", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      for bad_value <- [0, -5, "90", 12.5] do
        conn =
          conn
          |> authed(admin)
          |> patch(~p"/api/settings/visitor_retention_days", %{value: bad_value})

        assert %{"errors" => %{"value" => [_msg]}} = json_response(conn, 422)
      end

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/settings/visitor_retention_days", %{value: 45})

      assert %{"data" => %{"value" => 45}} = json_response(conn, 200)
      assert Settings.get_setting("visitor_retention_days", 90) == 45
    end

    test "an unknown setting key is a 422, not a write", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      conn =
        conn
        |> authed(admin)
        |> patch(~p"/api/settings/not_a_real_setting", %{value: "anything"})

      assert %{"errors" => %{"value" => [_msg]}} = json_response(conn, 422)
    end

    test "warden and report_viewer get 403", %{conn: conn} do
      for role <- ["warden", "report_viewer"] do
        user = user_fixture(%{role: role})

        conn =
          conn
          |> authed(user)
          |> patch(~p"/api/settings/visitor_retention_days", %{value: 45})

        assert json_response(conn, 403)
      end
    end
  end
end
