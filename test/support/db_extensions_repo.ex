defmodule Zaq.Test.DbExtensionsRepo do
  @moduledoc false

  use Ecto.Repo,
    otp_app: :zaq,
    adapter: Ecto.Adapters.Postgres
end
