defmodule Zaq.Storage.Supervisor do
  @moduledoc """
  Role marker for the `:storage` node role.

  Storage owns mounted-volume filesystem access and source-scoped access policy.
  `Zaq.NodeRouter` uses this registered supervisor to locate a node that can
  serve Storage events.
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
