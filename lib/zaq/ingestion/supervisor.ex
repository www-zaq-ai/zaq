defmodule Zaq.Ingestion.Supervisor do
  @moduledoc """
  Role marker for the `:ingestion` node role.

  This supervisor runs on whichever node carries the `:ingestion` role.
  `Zaq.NodeRouter` uses `Process.whereis/1` against this module to
  locate the ingestion node for cross-node RPC dispatch.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Supervisor.init([], strategy: :one_for_one)
  end
end
