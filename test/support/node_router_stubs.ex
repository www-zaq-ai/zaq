defmodule Zaq.TestSupport.NodeRouterStubs do
  @moduledoc false

  alias Zaq.TestSupport.NodeRouterPassthroughStub

  @doc """
  Installs a global passthrough stub for `Zaq.NodeRouterMock`.

  Uses `stub_with/2` so async `Task` children and parallel tests are less
  likely to lose a function stub installed via `stub/3`.
  """
  def stub_passthrough do
    Mox.set_mox_global()
    Mox.stub_with(Zaq.NodeRouterMock, NodeRouterPassthroughStub)
  end
end
