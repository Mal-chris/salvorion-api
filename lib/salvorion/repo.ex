defmodule Salvorion.Repo do
  use Ecto.Repo,
    otp_app: :salvorion,
    adapter: Ecto.Adapters.Postgres
end
