defmodule Zaq.Engine.Supervisor do
  @moduledoc """
  Top-level supervisor for the Engine service.

  The Engine is the orchestrator of ZAQ. It manages ingestion channel adapters
  (document sources) and retrieval channel adapters (messaging platforms).

  ## Startup

  Started when `:engine` is included in the `:roles` config or `ROLES` env var.

      # config/dev.exs
      config :zaq, roles: [:bo, :agent, :ingestion, :channels, :engine]

      # or via env
      ROLES=engine iex --sname engine@localhost --cookie zaq_dev -S mix

  ## Children

  - `Zaq.Engine.Telemetry.Supervisor` — runtime telemetry collection
  - `Zaq.Engine.IngestionSupervisor` — supervises all ingestion channel adapters
  - `Zaq.Engine.RetrievalSupervisor` — supervises all retrieval channel adapters
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      Zaq.Engine.Telemetry.Supervisor,
      Zaq.Engine.IngestionSupervisor,
      Zaq.Engine.RetrievalSupervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
