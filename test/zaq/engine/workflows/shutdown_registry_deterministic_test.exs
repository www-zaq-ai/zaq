defmodule Zaq.Engine.Workflows.ShutdownRegistryDeterministicTest do
  use ExUnit.Case, async: false

  test "registry owner dies while selection is in progress" do
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: Enum.flat_map(:code.get_path(), &[~c"-pa", &1])
      })

    try do
      assert {:ok, :ok} = :peer.call(peer, Zaq.RegistryLookupProbe, :run, [], 15_000)
    after
      :peer.stop(peer)
    end
  end
end
