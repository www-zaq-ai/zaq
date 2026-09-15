defmodule Zaq.TestSupport.PersonResourceConfig do
  @moduledoc false
  def get(:zaq, :person_conversation_resource_node_router_module, _), do: Zaq.NodeRouterMock
  def get(app, key, default), do: Application.get_env(app, key, default)
end
