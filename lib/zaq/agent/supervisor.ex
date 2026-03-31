defmodule Zaq.Agent.Supervisor do
  @moduledoc """
  Role marker for the `:agent` node role.

  This supervisor runs on whichever node carries the `:agent` role.
  `Zaq.NodeRouter` uses `Process.whereis/1` against this module to
  locate the agent node for cross-node RPC dispatch.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = []

    Supervisor.init(children, strategy: :one_for_one)
  end
end
