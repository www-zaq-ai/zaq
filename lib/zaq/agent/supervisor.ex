defmodule Zaq.Agent.Supervisor do
  @moduledoc """
  Supervisor for Agent-related processes.
  Currently a placeholder — will host Agent-specific GenServers
  or workers as they are added.
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
