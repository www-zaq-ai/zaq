defmodule Zaq.Channels.Supervisor do
  @moduledoc """
  Top-level supervisor for shared channel infrastructure.

  Starts `ChatBridgeServer`, which owns the Jido.Chat state and routes inbound
  Mattermost webhook events through the bridge pipeline.

  Note: Retrieval and ingestion channel adapters are managed by
  `Zaq.Engine.RetrievalSupervisor` and `Zaq.Engine.IngestionSupervisor`.

  PendingQuestions is managed by the licensed KnowledgeGap feature module.
  """

  use Supervisor

  alias Zaq.Channels.ChatBridgeServer

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    children = [
      ChatBridgeServer
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
