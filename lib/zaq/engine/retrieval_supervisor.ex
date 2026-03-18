defmodule Zaq.Engine.RetrievalSupervisor do
  @moduledoc """
  Supervises all active retrieval channel adapters.

  On startup, loads all enabled retrieval channel configs from the database
  and starts the corresponding adapter processes. If no configs are found,
  the supervisor starts empty without crashing.

  ## Adapter resolution

  Adapters are resolved from the `provider` field on `Zaq.Channels.ChannelConfig`.
  Each provider string maps to an adapter module:

      "mattermost" => Zaq.Channels.Retrieval.Mattermost
      "slack"      => Zaq.Channels.Retrieval.Slack
      "email"      => Zaq.Channels.Retrieval.Email

  ## Adding a new retrieval adapter

  1. Implement `Zaq.Engine.RetrievalChannel` behaviour
  2. Add the provider → module mapping to `@adapters` below
  3. Create a channel config in BO with `kind: :retrieval` and the matching provider
  """

  alias Zaq.Channels.ChannelConfig
  use Supervisor

  require Logger

  @adapters %{
    "mattermost" => Zaq.Channels.Retrieval.Mattermost,
    "slack" => Zaq.Channels.Retrieval.Slack,
    "email" => Zaq.Channels.Retrieval.Email
  }

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the adapter module for a given provider string, or nil if unknown.
  """
  def adapter_for(provider), do: Map.get(@adapters, provider)

  @impl true
  def init(_opts) do
    children =
      :retrieval
      |> load_configs()
      |> Enum.flat_map(&build_child_spec/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Private ---

  defp load_configs(kind) do
    case ChannelConfig.list_enabled_by_kind(kind) do
      [] ->
        Logger.info(
          "[RetrievalSupervisor] No enabled retrieval channel configs found, starting empty."
        )

        []

      configs ->
        configs
    end
  end

  defp build_child_spec(config) do
    case Map.get(@adapters, config.provider) do
      nil ->
        Logger.warning(
          "[RetrievalSupervisor] Unknown retrieval provider #{inspect(config.provider)}, skipping."
        )

        []

      adapter_module ->
        [
          %{
            id: {adapter_module, config.id},
            start: {adapter_module, :connect, [config]},
            restart: :permanent
          }
        ]
    end
  end
end
