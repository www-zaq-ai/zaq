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
  alias Zaq.Agent.RuntimeSync
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.InternalBoundaries

  @doc """
  Dispatches an agent-role event routed by `Zaq.NodeRouter`.

  Supported actions:

  - `:run_pipeline` — resolves caller identity via `IdentityPlug`, then routes to
    `Pipeline.run/2` (full RAG path) or `Executor.run/2` (direct agent run) depending
    on whether `event.assigns["agent_selection"]` carries a non-nil `agent_id`.

  - `:invoke` — generic passthrough to `InternalBoundaries.invoke_request/1`.

  - `:mcp_test_list_tools` — proxies `MCP.test_list_tools/2` for the BO endpoint
    connectivity check. Expects `event.request` to be `%{endpoint_id: id}`.

  - `:configured_agent_updated` — delegates to `RuntimeSync.configured_agent_updated/3`.
    Expects `event.request` to carry `:id` (integer) and `:attrs` (map).

  - `:configured_agent_deleted` — delegates to `RuntimeSync.configured_agent_deleted/2`.
    Expects `event.request` to carry `:id` (integer).

  - `:mcp_endpoint_updated` — delegates to `RuntimeSync.mcp_endpoint_updated/2`.
    Expects `event.request` to be a map with an `:action` key.

  - Any other action — returns `{:error, {:unsupported_action, action}}`.

  All clauses return the event struct with `response` set. Runtime errors from
  `RuntimeSync` are normalized to `{:error, {:action_failed, reason}}` unless
  they are already `{:error, {:invalid_request, _}}`.
  """
  @impl true
  def handle_event(%Event{} = event, :run_pipeline, _context) do
    case event.request do
      %Incoming{} = incoming ->
        pipeline_opts = Keyword.get(event.opts, :pipeline_opts, [])
        pipeline_module = Keyword.get(event.opts, :pipeline_module, Pipeline)
        executor_module = Keyword.get(event.opts, :executor_module, Executor)

        # Identity resolution moves to Executor once a generic contract replaces the BO IdentityPlug.
        incoming = identity_plug_mod(event.opts).call(incoming, pipeline_opts)

        outgoing =
          case selected_agent_id(event.assigns) do
            nil ->
              pipeline_module.run(
                incoming,
                Keyword.put(pipeline_opts, :scope, Executor.derive_scope(incoming))
              )

            selected_id ->
              executor_module.run(incoming,
                agent_id: selected_id,
                scope: Executor.derive_scope(incoming),
                history: Keyword.get(pipeline_opts, :history, %{}),
                telemetry_dimensions: Keyword.get(pipeline_opts, :telemetry_dimensions, %{})
              )
          end

        %{event | response: outgoing}

      other ->
        invalid_request_response(event, other)
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
        invalid_request_response(event, other)
    end
  end

  # Temporary: runtime replacement still enters through update action.
  # Stop is enough because servers restart lazily on next message.
  def handle_event(%Event{} = event, :configured_agent_updated, _context) do
    runtime_sync_module = Keyword.get(event.opts, :runtime_sync_module, RuntimeSync)

    case updated_request(event.request) do
      {:ok, id, attrs} ->
        %{
          event
          | response:
              normalize_action_error(runtime_sync_module.configured_agent_updated(id, attrs))
        }

      other ->
        invalid_request_response(event, other)
    end
  end

  def handle_event(%Event{} = event, :configured_agent_deleted, _context) do
    runtime_sync_module = Keyword.get(event.opts, :runtime_sync_module, RuntimeSync)

    case deleted_request(event.request) do
      {:ok, id} ->
        %{
          event
          | response: normalize_action_error(runtime_sync_module.configured_agent_deleted(id))
        }

      other ->
        invalid_request_response(event, other)
    end
  end

  def handle_event(%Event{} = event, :mcp_endpoint_updated, _context) do
    runtime_sync_module = Keyword.get(event.opts, :runtime_sync_module, RuntimeSync)

    case event.request do
      request when is_map(request) ->
        %{
          event
          | response: normalize_action_error(runtime_sync_module.mcp_endpoint_updated(request))
        }

      other ->
        invalid_request_response(event, other)
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

  defp updated_request(%{} = request) do
    with {:ok, id} when is_integer(id) <- fetch_key(request, :id),
         {:ok, attrs} when is_map(attrs) <- fetch_key(request, :attrs) do
      {:ok, id, attrs}
    else
      _ -> request
    end
  end

  defp updated_request(other), do: other

  defp deleted_request(%{} = request) do
    case fetch_key(request, :id) do
      {:ok, id} when is_integer(id) -> {:ok, id}
      _ -> request
    end
  end

  defp deleted_request(other), do: other

  defp fetch_key(request, key) when is_map(request) and is_atom(key) do
    cond do
      Map.has_key?(request, key) -> {:ok, Map.get(request, key)}
      Map.has_key?(request, Atom.to_string(key)) -> {:ok, Map.get(request, Atom.to_string(key))}
      true -> :error
    end
  end

  defp normalize_action_error({:error, {:invalid_request, _} = reason}), do: {:error, reason}
  defp normalize_action_error({:error, reason}), do: {:error, {:action_failed, reason}}
  defp normalize_action_error(other), do: other

  defp invalid_request_response(event, other),
    do: %{event | response: {:error, {:invalid_request, other}}}
end
