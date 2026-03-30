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

  alias Zaq.Engine.AdapterSupervisor
  use Supervisor

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
    register_dispatch_hooks()

    children =
      AdapterSupervisor.children_for(:retrieval, @adapters,
        start_fun: :connect,
        supervisor_name: "RetrievalSupervisor",
        kind_label: "retrieval"
      )

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Private ---

  @dispatch_hooks %{
    "mattermost" => Zaq.Channels.Retrieval.Mattermost.DispatchHook
  }

  defp register_dispatch_hooks do
    Enum.each(@dispatch_hooks, fn {_provider, hook_module} ->
      hook_module.register()
    end)
  end
end
