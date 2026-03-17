defmodule Zaq.Engine.SupervisorTest do
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Zaq.Engine.Supervisor

  test "init/1 defines ingestion and retrieval supervisors" do
    assert {:ok, {spec, children}} = Supervisor.init([])
    assert spec.strategy == :one_for_one

    assert Enum.map(children, & &1.id) == [
             Zaq.Engine.IngestionSupervisor,
             Zaq.Engine.RetrievalSupervisor
           ]
  end
end
