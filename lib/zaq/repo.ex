defmodule Zaq.Repo do
  use Ecto.Repo,
    otp_app: :zaq,
    adapter: Ecto.Adapters.Postgres
end
