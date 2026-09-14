defmodule SalvorionWeb.VisitorControllerTest do
  use SalvorionWeb.ConnCase, async: false

  import Salvorion.AccountsFixtures

  alias Salvorion.Activations

  describe "POST /api/visitors" do
    test "admin, osh_officer and warden can register a visitor; report_viewer gets 403", %{
      conn: conn
    } do
      for role <- ["admin", "osh_officer", "warden"] do
        user = user_fixture(%{role: role})

        conn =
          conn
          |> authed(user)
          |> post(~p"/api/visitors", %{
            first_name: "Vera",
            last_name: "Guest",
            visitor_host: "Someone"
          })

        assert %{
                 "data" => %{"person" => %{"id_number" => id_number}, "pass" => _, "event" => nil}
               } =
                 json_response(conn, 201)

        assert id_number =~ ~r/^VIS-[0-9A-HJKMNP-TV-Z]{8}$/
      end

      viewer = user_fixture(%{role: "report_viewer"})

      conn =
        conn
        |> authed(viewer)
        |> post(~p"/api/visitors", %{first_name: "V", last_name: "G", visitor_host: "X"})

      assert json_response(conn, 403)
    end

    test "with an activation_id, also signs the visitor in", %{conn: conn} do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      conn =
        conn
        |> authed(officer)
        |> post(~p"/api/visitors", %{
          first_name: "Vex",
          last_name: "Guest",
          visitor_host: "Someone",
          activation_id: activation.id
        })

      assert %{"data" => %{"event" => %{"kind" => "visitor_registered", "status" => "present"}}} =
               json_response(conn, 201)
    end

    test "a failed sign-in still returns 201 with the person created, plus sign_in_error", %{
      conn: conn
    } do
      officer = user_fixture(%{role: "osh_officer"})

      {:ok, activation} =
        Activations.start_activation(%{activation_type: "drill"}, actor: officer)

      {:ok, closed} = Activations.close_activation(activation, actor: officer)

      conn =
        conn
        |> authed(officer)
        |> post(~p"/api/visitors", %{
          first_name: "Late",
          last_name: "Guest",
          visitor_host: "Someone",
          activation_id: activation.id,
          client_timestamp: DateTime.add(closed.closed_at, 600) |> DateTime.to_iso8601()
        })

      assert %{
               "data" => %{
                 "person" => %{"id_number" => "VIS-" <> _},
                 "sign_in_error" => "activation_closed"
               }
             } =
               json_response(conn, 201)
    end
  end
end
