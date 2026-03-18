defmodule Zaq.Ingestion.Supervisor do
  @moduledoc """
  Supervisor for Ingestion-related processes.
  Started when the :ingestion role is active.

  Oban is started in the root application supervisor so it is available
  to all roles — see `Zaq.Application`.
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
