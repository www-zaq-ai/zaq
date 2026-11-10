defmodule Zaq.TestSupport.AgentConfig do
  @moduledoc false

  def get(:zaq, :agent_server_drain_timeout_ms, _default, opts),
    do: Keyword.get(opts, :test_drain_timeout_ms, 20)

  def get(app, key, default, _opts), do: Zaq.Config.get(app, key, default)
end
