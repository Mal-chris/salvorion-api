# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Seeds one System Administrator so there is a way to log in. Idempotent:
# re-running does nothing if the admin already exists.
#
# The password is a fixed development value, printed below when the seed
# creates the user. Change it (or replace the user) before any non-local use.

alias Salvorion.Accounts
alias Salvorion.Accounts.User
alias Salvorion.Repo

admin_email = "admin@salvorion.local"
admin_password = "salvorion-dev-admin"

case Repo.get_by(User, email: admin_email) do
  %User{} ->
    IO.puts("[seeds] admin #{admin_email} already exists; nothing to do")

  nil ->
    # No acting user exists yet at bootstrap, so this audit row has a nil
    # actor. This is the one deliberate nil-actor case in the Accounts context.
    case Accounts.register_user(%{email: admin_email, password: admin_password, role: "admin"}) do
      {:ok, user} ->
        IO.puts("""
        [seeds] created System Administrator
          id:       #{user.id}
          email:    #{admin_email}
          password: #{admin_password}
        """)

      {:error, changeset} ->
        raise "[seeds] could not create admin: #{inspect(changeset.errors)}"
    end
end
