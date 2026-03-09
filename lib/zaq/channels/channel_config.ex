defmodule Zaq.Channels.ChannelConfig do
  @moduledoc """
  Schema for channel connector configurations stored in the database.
  Single-tenant: one config per provider (mattermost, slack, teams, etc.).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_providers ~w(mattermost slack teams)
  @test_message "✅ **Zaq Connection Test**\nThis is an automated test message. If you see this, the channel is configured correctly."

  @provider_api_modules %{
    "mattermost" => Zaq.Channels.Mattermost.API
  }

  schema "channel_configs" do
    field :name, :string
    field :provider, :string
    field :url, :string
    field :token, :string
    field :enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [:name, :provider, :url, :token, :enabled])
    |> validate_required([:name, :provider, :url, :token])
    |> validate_inclusion(:provider, @valid_providers)
    |> unique_constraint(:provider)
  end

  def get_by_provider(provider) do
    Zaq.Repo.get_by(__MODULE__, provider: provider, enabled: true)
  end

  def test_connection(%__MODULE__{} = config, channel_id) do
    case Map.get(@provider_api_modules, config.provider) do
      nil -> {:error, "Testing not supported for #{config.provider}"}
      api_module -> api_module.send_message(config, channel_id, @test_message)
    end
  end
end
