defmodule Zaq.Channels.Supervisor do
  @moduledoc """
  Top-level supervisor for all channel connectors.
  """

  use Supervisor

  def start_link(_opts) do
    Supervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    children = [
      Zaq.Channels.Mattermost.Supervisor
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
