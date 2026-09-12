defmodule SalvorionWeb.RosterImportControllerTest do
  use SalvorionWeb.ConnCase, async: true

  import Salvorion.AccountsFixtures

  @csv_path Path.join(System.tmp_dir!(), "roster_import_controller_test.csv")

  setup do
    File.write!(@csv_path, """
    type,id_number,first_name,last_name,email,phone,department_code,programme_code
    staff,CTRL-TEST-1,Ada,Lovelace,ada@example.com,,,
    """)

    on_exit(fn -> File.rm(@csv_path) end)
    :ok
  end

  describe "POST /api/roster-imports" do
    test "admin uploads a valid CSV", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      upload = %Plug.Upload{path: @csv_path, filename: "roster.csv", content_type: "text/csv"}

      conn = conn |> authed(admin) |> post(~p"/api/roster-imports", %{file: upload})

      assert %{"data" => %{"provider" => "file_import", "total_records" => 1, "error_count" => 0}} =
               json_response(conn, 201)

      assert Salvorion.Roster.get_person_by_id_number("CTRL-TEST-1")
    end

    test "a non-CSV content-type is rejected before reaching the importer", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      upload = %Plug.Upload{path: @csv_path, filename: "roster.txt", content_type: "text/plain"}
      conn = conn |> authed(admin) |> post(~p"/api/roster-imports", %{file: upload})

      assert json_response(conn, 415)
      refute Salvorion.Roster.get_person_by_id_number("CTRL-TEST-1")
    end

    test "osh_officer gets 403 (import is admin-only)", %{conn: conn} do
      osh = user_fixture(%{role: "osh_officer"})
      upload = %Plug.Upload{path: @csv_path, filename: "roster.csv", content_type: "text/csv"}

      conn = conn |> authed(osh) |> post(~p"/api/roster-imports", %{file: upload})
      assert json_response(conn, 403)
    end

    test "no file at all is a 422, not a crash", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})
      conn = conn |> authed(admin) |> post(~p"/api/roster-imports", %{})
      assert json_response(conn, 422)
    end
  end

  describe "GET /api/roster-imports" do
    test "admin lists; warden gets 403", %{conn: conn} do
      admin = user_fixture(%{role: "admin"})

      assert %{"data" => list} =
               json_response(conn |> authed(admin) |> get(~p"/api/roster-imports"), 200)

      assert is_list(list)

      warden = user_fixture(%{role: "warden"})
      assert json_response(conn |> authed(warden) |> get(~p"/api/roster-imports"), 403)
    end
  end
end
