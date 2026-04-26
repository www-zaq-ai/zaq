defmodule Zaq.Agent.Api do
  @moduledoc """
  Agent role boundary module used by `Zaq.NodeRouter.dispatch/1`.

  Handles the `:run_pipeline` action by resolving the caller identity via
  `IdentityPlug`, scoping the request, and dispatching to either `Executor`
  (direct agent run when an agent is selected) or `Pipeline` (full RAG pipeline).

  Identity resolution currently lives here as a temporary step: `IdentityPlug`
  is a BO-specific Phoenix plug and its invocation belongs closer to the HTTP
  boundary. It will move into `Executor` once a generic identity contract
  (decoupled from plug concerns) is in place.
  """

  @behaviour Zaq.InternalBoundaries

  alias Zaq.Agent.Executor
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Pipeline
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

        # Identity resolution moves to Executor once a generic contract replaces the BO IdentityPlug.
        incoming = identity_plug_mod(event.opts).call(incoming, pipeline_opts)
        scope = Executor.derive_scope(incoming)

        outgoing =
          case selected_agent_id(event.assigns) do
            nil ->
              pipeline_module.run(incoming, Keyword.put(pipeline_opts, :scope, scope))

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
      %{"agent_id" => id} when id not in [nil, ""] -> id
      %{agent_id: id} when id not in [nil, ""] -> id
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

  defp identity_plug_mod(opts) do
    Keyword.get(
      opts,
      :identity_plug,
      Application.get_env(:zaq, :api_identity_plug_module, Zaq.People.IdentityPlug)
    )
  end
end
