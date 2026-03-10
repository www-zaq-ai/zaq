defmodule Zaq.Channels.Supervisor do
  @moduledoc """
  Top-level supervisor for shared channel infrastructure.

  Note: Retrieval and ingestion channel adapters are no longer started here.
  They are managed by `Zaq.Engine.RetrievalSupervisor` and
  `Zaq.Engine.IngestionSupervisor` respectively.

  This supervisor is kept for any shared channel infrastructure that is
  not adapter-specific (e.g. `PendingQuestions`).
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    children = [
      Zaq.Channels.PendingQuestions
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
