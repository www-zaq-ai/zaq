defmodule Zaq.Repo do
  @moduledoc """
  Application PostgreSQL repository. URL and CA validation happens at Repo
  initialization so configuration files remain readable before application loading.
  """

  use Ecto.Repo,
    otp_app: :zaq,
    adapter: Ecto.Adapters.Postgres

  @impl true
  def init(_type, config) do
    {ca_file, config} = Keyword.pop(config, :database_ssl_ca_cert_file)

    case Keyword.pop(config, :url) do
      {nil, config} -> {:ok, config}
      {url, config} -> {:ok, Keyword.merge(config, Zaq.DatabaseConfig.from_url!(url, ca_file))}
    end
  end
end
