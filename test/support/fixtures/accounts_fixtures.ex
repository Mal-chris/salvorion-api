defmodule Salvorion.AccountsFixtures do
  @moduledoc "Test helpers for creating Accounts entities."

  alias Salvorion.Accounts

  def unique_email, do: "user#{System.unique_integer([:positive])}@salvorion.test"
  def valid_password, do: "correct-horse-battery"

  def user_fixture(attrs \\ %{}, opts \\ []) do
    attrs =
      Enum.into(attrs, %{
        email: unique_email(),
        password: valid_password(),
        role: "admin"
      })

    {:ok, user} = Accounts.register_user(attrs, opts)
    user
  end

  def device_fixture(user, attrs \\ %{}, opts \\ []) do
    {:ok, device} = Accounts.register_device(user, Enum.into(attrs, %{platform: "android"}), opts)
    device
  end

  def zone_fixture do
    {:ok, ap} =
      Salvorion.Repo.insert(
        Salvorion.Locations.AssemblyPoint.changeset(%Salvorion.Locations.AssemblyPoint{}, %{
          name: "AP #{System.unique_integer([:positive])}"
        })
      )

    {:ok, zone} =
      Salvorion.Repo.insert(
        Salvorion.Locations.Zone.changeset(%Salvorion.Locations.Zone{}, %{
          number: System.unique_integer([:positive]),
          assembly_point_id: ap.id
        })
      )

    zone
  end
end
