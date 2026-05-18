defmodule ZaqWeb.Live.BO.System.SystemConfig.AgentsTab do
  @moduledoc """
  Tab component for the BO system configuration page.
  """
  use ZaqWeb, :html
  attr :global_agent_options, :list, required: true
  attr :global_default_agent_id, :any, required: true

  def panel(assigns) do
    ~H"""
    <div class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden">
      <div class="px-8 py-5 border-b border-black/[0.06] bg-[#fafafa]">
        <h2 class="font-mono text-[0.95rem] font-bold text-black">Agents</h2>
        <p class="font-mono text-[0.75rem] text-black/40 mt-0.5">
          Configure system-wide defaults used when channel-level routing does not select a configured agent.
        </p>
      </div>
      <div class="px-8 py-6">
        <label class="font-mono text-[0.68rem] font-semibold text-black/60 uppercase tracking-wider block mb-2">
          Global Default Agent
        </label>
        <form phx-submit="save_global_default_agent" class="flex items-center gap-2">
          <select
            id="global-default-agent-select"
            name="global_default_agent_id"
            class="w-full max-w-md font-mono text-[0.82rem] text-black border border-black/10 rounded-xl h-10 px-3 bg-white focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 focus:border-[#03b6d4]"
          >
            <option value="" selected={is_nil(@global_default_agent_id)}>
              Default Zaq Agent
            </option>
            <option
              :for={{name, id} <- @global_agent_options}
              value={id}
              selected={to_string(@global_default_agent_id || "") == to_string(id)}
            >
              {name}
            </option>
          </select>
          <button
            type="submit"
            class="font-mono text-[0.72rem] px-3 py-2 rounded-lg border border-black/10 text-black/60 hover:text-black hover:border-black/20"
          >
            Save
          </button>
        </form>
      </div>
    </div>
    """
  end
end
