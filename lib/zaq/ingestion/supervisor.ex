defmodule Zaq.Ingestion.Supervisor do
  @moduledoc """
  Supervisor for Ingestion-related processes.
  Started when the :ingestion role is active.
  Starts Oban for background job processing.
  """

  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      {Oban, Application.fetch_env!(:zaq, Oban)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
