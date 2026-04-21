defmodule Zaq.Channels.RetrievalChannel do
  @moduledoc """
  Schema for retrieval channels — specific channels within a messaging platform
  that ZAQ monitors and responds to @zaq mentions.

  Each record links a platform channel (e.g. a Mattermost public channel) to a
  `ChannelConfig` (connection credentials). Only messages from active retrieval
  channels are forwarded to the Agent pipeline.

  ## Example

      %RetrievalChannel{
        channel_config_id: 1,
        channel_id: "abc123xyz",
        channel_name: "engineering",
        team_id: "team789",
        team_name: "Acme Corp",
        active: true
      }
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Repo

  schema "retrieval_channels" do
    belongs_to :channel_config, ChannelConfig
    belongs_to :configured_agent, ConfiguredAgent
    field :channel_id, :string
    field :channel_name, :string
    field :team_id, :string
    field :team_name, :string
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(retrieval_channel, attrs) do
    retrieval_channel
    |> cast(attrs, [
      :channel_config_id,
      :channel_id,
      :channel_name,
      :team_id,
      :team_name,
      :active,
      :configured_agent_id
    ])
    |> validate_required([:channel_config_id, :channel_id, :channel_name, :team_id, :team_name])
    |> foreign_key_constraint(:channel_config_id)
    |> foreign_key_constraint(:configured_agent_id)
    |> unique_constraint([:channel_config_id, :channel_id],
      message: "this channel is already configured"
    )
  end

  @doc """
  Returns all active retrieval channels for a given channel config.
  """
  def list_active_by_config(config_id) do
    __MODULE__
    |> where([r], r.channel_config_id == ^config_id and r.active == true)
    |> Repo.all()
  end

  @doc """
  Returns all active retrieval channel IDs for a given provider.
  Used by the WebSocket handler to filter incoming messages.
  """
  def active_channel_ids(provider) do
    __MODULE__
    |> join(:inner, [r], c in ChannelConfig, on: r.channel_config_id == c.id)
    |> where([r, c], c.provider == ^provider and c.enabled == true and r.active == true)
    |> select([r], r.channel_id)
    |> Repo.all()
  end

  @doc """
  Returns all retrieval channels (active and inactive) for a given config.
  """
  def list_by_config(config_id) do
    __MODULE__
    |> where([r], r.channel_config_id == ^config_id)
    |> order_by(asc: :channel_name)
    |> Repo.all()
  end

  @doc """
  Finds a retrieval channel by config and platform channel ID.
  """
  def get_by_config_and_channel(config_id, channel_id) do
    Repo.get_by(__MODULE__, channel_config_id: config_id, channel_id: channel_id)
  end
end
