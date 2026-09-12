defmodule Salvorion.Repo.Migrations.AddObanJobsTable do
  use Ecto.Migration

  def up do
    Oban.Migration.up()
  end

  # Always safe to roll all the way back down.
  def down do
    Oban.Migration.down(version: 1)
  end
end
