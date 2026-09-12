# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Seeds one System Administrator so there is a way to log in, then the
# assembly point / zone / area hierarchy from the OSH Emergency Assembly Point
# Guide (priv/repo/seeds/locations_seed.exs). Both parts are idempotent:
# re-running creates nothing that already exists.
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

# The OSH Emergency Assembly Point Guide: assembly points, zones, areas and
# the departments named in it. Real data; see the file for the rules applied.
Code.require_file("seeds/locations_seed.exs", __DIR__)
Salvorion.Seeds.Locations.run()
