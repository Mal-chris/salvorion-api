defmodule SalvorionWeb.UserController do
  @moduledoc """
  Users and roles (Task 3). Every action is admin-only
  (`SalvorionWeb.RBAC`, Document 10 section 1, "Manage users and roles").
  """
  use SalvorionWeb, :controller

  action_fallback SalvorionWeb.FallbackController

  alias Salvorion.Accounts
  alias Salvorion.Accounts.User

  def create(conn, params) do
    with {:ok, user} <- Accounts.register_user(params, actor: conn.assigns.current_user_id) do
      conn |> put_status(:created) |> json(%{data: user_json(user)})
    end
  end

  def index(conn, _params) do
    json(conn, %{data: Enum.map(Accounts.list_users(), &user_json/1)})
  end

  def show(conn, %{"id" => id}) do
    json(conn, %{data: user_json(Accounts.get_user!(id))})
  end

  def update_role(conn, %{"id" => id, "role" => role}) do
    with {:ok, user} <-
           Accounts.update_user_role(Accounts.get_user!(id), role,
             actor: conn.assigns.current_user_id
           ) do
      json(conn, %{data: user_json(user)})
    end
  end

  def deactivate(conn, %{"id" => id}) do
    with {:ok, user} <-
           Accounts.deactivate_user(Accounts.get_user!(id), actor: conn.assigns.current_user_id) do
      json(conn, %{data: user_json(user)})
    end
  end

  defp user_json(%User{} = u) do
    %{
      id: u.id,
      email: u.email,
      role: u.role,
      active: u.active,
      person_id: u.person_id,
      inserted_at: u.inserted_at
    }
  end
end
