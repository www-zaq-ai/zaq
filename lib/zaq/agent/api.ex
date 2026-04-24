defmodule Zaq.Agent.Api do
  @moduledoc """
  Agent role boundary module used by `Zaq.NodeRouter.dispatch/1`.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Agent.Executor
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Pipeline
  alias Zaq.Agent.ServerManager
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @impl true
  def handle_event(%Event{} = event, :run_pipeline, _context) do
    case event.request do
      %Incoming{} = incoming ->
        pipeline_opts = Keyword.get(event.opts, :pipeline_opts, [])
        pipeline_module = Keyword.get(event.opts, :pipeline_module, Pipeline)
        executor_module = Keyword.get(event.opts, :executor_module, Executor)
        server_manager_mod = server_manager_mod(event.opts)

        # TODO: move identity resolution to Executor once executor owns the full lifecycle
        incoming = identity_plug_mod(event.opts).call(incoming, pipeline_opts)
        scope = derive_scope(incoming)

        outgoing =
          case selected_agent_id(event.assigns) do
            nil ->
              {:ok, server_ref} =
                server_manager_mod.ensure_answering_server("answering_#{scope}")

              pipeline_module.run(incoming, Keyword.put(pipeline_opts, :server, server_ref))

            selected_id ->
              executor_module.run(incoming,
                agent_id: selected_id,
                scope: scope,
                history: Keyword.get(pipeline_opts, :history, %{}),
                telemetry_dimensions: Keyword.get(pipeline_opts, :telemetry_dimensions, %{})
              )
          end

        %{event | response: outgoing}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, :invoke, _context),
    do: InternalBoundaries.invoke_request(event)

  def handle_event(%Event{} = event, :mcp_test_list_tools, _context) do
    mcp_module = Keyword.get(event.opts, :mcp_module, MCP)

    case event.request do
      %{endpoint_id: endpoint_id} ->
        opts = mcp_test_opts(event.opts)
        %{event | response: mcp_module.test_list_tools(endpoint_id, opts)}

      other ->
        %{event | response: {:error, {:invalid_request, other}}}
    end
  end

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end

  defp selected_agent_id(assigns) when is_map(assigns) do
    case Map.get(assigns, "agent_selection") do
      %{"agent_id" => id} when id not in [nil, ""] -> normalize_selected_id(id)
      %{agent_id: id} when id not in [nil, ""] -> normalize_selected_id(id)
      _ -> nil
    end
  end

  defp selected_agent_id(_), do: nil

  defp mcp_test_opts(opts) when is_list(opts) do
    case Keyword.get(opts, :mcp_test_opts, []) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp derive_scope(%Incoming{person_id: person_id}) when not is_nil(person_id),
    do: to_string(person_id)

  defp derive_scope(%Incoming{metadata: %{session_id: sid}}) when is_binary(sid) and sid != "",
    do: sid

  defp derive_scope(_), do: "anonymous"

  defp identity_plug_mod(opts) do
    Keyword.get(
      opts,
      :identity_plug,
      Application.get_env(:zaq, :api_identity_plug_module, Zaq.People.IdentityPlug)
    )
  end

  defp server_manager_mod(opts) do
    Keyword.get(
      opts,
      :server_manager,
      Application.get_env(:zaq, :api_server_manager_module, ServerManager)
    )
  end
end
