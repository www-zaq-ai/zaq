defmodule Zaq.Engine.IngestionSupervisor do
  @moduledoc """
  Supervises all active ingestion channel adapters.

  On startup, loads all enabled ingestion channel configs from the database
  and starts the corresponding adapter processes. If no configs are found,
  the supervisor starts empty without crashing.

  ## Adapter resolution

  This supervisor only starts engine-owned ingestion adapters.
  Channel-managed Data Source providers are started by `Zaq.Channels.Supervisor`.

  ## Adding a new ingestion adapter

  1. Implement `Zaq.Engine.IngestionChannel` behaviour
  2. Add the provider → module mapping to `@adapters` below
  3. Create a channel config in BO with `kind: :ingestion` and the matching provider
  """

  alias Zaq.Engine.ChannelAdapterLoader
  use Supervisor

  @adapters %{}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children =
      ChannelAdapterLoader.children_for(:ingestion, @adapters,
        start_fun: :start_link,
        supervisor_name: "IngestionSupervisor",
        kind_label: "ingestion"
      )

    Supervisor.init(children, strategy: :one_for_one)
  end

  # --- Private ---
end
