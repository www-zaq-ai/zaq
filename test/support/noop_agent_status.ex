defmodule Zaq.TestSupport.NoopAgentStatus do
  @moduledoc false

  def broadcast(incoming, _stage, _message, _node_router, _opts), do: incoming
end
