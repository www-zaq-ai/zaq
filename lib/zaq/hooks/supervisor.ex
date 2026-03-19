defmodule Zaq.Hooks.Supervisor do
  @moduledoc """
  Supervises the ZAQ hook registry.

  Started as a base child in `Zaq.Application` (before role-specific supervisors)
  so that hooks are available across all node roles.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [Zaq.Hooks.Registry]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
