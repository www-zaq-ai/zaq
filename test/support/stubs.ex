defmodule Zaq.Test.Stubs do
  @moduledoc false

  @doc """
  Stubs `NodeRouterMock.dispatch/1` with a no-op for the current test process.

  Call this from any test that triggers NodeRouter dispatch but does not care
  about the dispatched events. Tests that want to assert on dispatched events
  should override this stub locally with their own `Mox.stub/3` call.
  """
  def stub_node_router do
    Mox.stub(Zaq.NodeRouterMock, :dispatch, fn event -> event end)
  rescue
    # Mox is in global mode and this process is not the global owner.
    ArgumentError -> :ok
  end
end
