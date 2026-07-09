defmodule ZaqWeb.Live.BO.Communication.AgentRoutingOptions do
  @moduledoc "BO-facing option formatting for channel agent routing selects."

  alias Zaq.Agent
  alias Zaq.Channels.AgentRouting

  @doc "Returns dropdown options with the centralized NONE choice prepended."
  @spec agent_options(module()) :: [{String.t(), term()}]
  def agent_options(agent_module \\ Agent) when is_atom(agent_module) do
    [{"NONE", AgentRouting.none_value()}] ++
      Enum.map(agent_module.list_conversation_enabled_agents(), fn agent ->
        {agent.name, agent.id}
      end)
  end
end
