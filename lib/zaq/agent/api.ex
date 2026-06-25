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

  alias Zaq.Agent

  alias Zaq.Agent.{
    ErrorMessage,
    Executor,
    Factory,
    MCP,
    Pipeline,
    PromptGuard,
    RequestRegistry,
    RuntimeSync,
    Status
  }

  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.{Event, EventHop}
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
        status_mod = Keyword.get(event.opts, :status_module, Status)
        node_router_mod = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

        incoming =
          status_mod.broadcast(
            incoming,
            :validating,
            "Checking your request…",
            node_router_mod
          )

        prompt_guard_mod = Keyword.get(event.opts, :prompt_guard, PromptGuard)

        case prompt_guard_mod.validate(incoming.content) do
          {:error, _reason} ->
            maybe_dispatch_return_hop(event, incoming, guard_error_outgoing(incoming))

          {:ok, _} ->
            dispatch_pipeline(event, incoming)
        end

      other ->
        invalid_request_response(event, other)
    end
  end

  def handle_event(%Event{} = event, :inspect_request, _context) do
    case request_id_request(event.request) do
      {:ok, request_id} -> %{event | response: RequestRegistry.get(request_id)}
      {:error, reason} -> %{event | response: {:error, {:invalid_request, reason}}}
    end
  end

  def handle_event(%Event{} = event, action, _context)
      when action in [:steer_request, :inject_request] do
    factory_module = Keyword.get(event.opts, :factory_module, Factory)

    with {:ok, request_id} <- request_id_request(event.request),
         {:ok, content} <- content_request(event.request),
         {:ok, %{server_id: server_id}} when not is_nil(server_id) <-
           RequestRegistry.get(request_id) do
      response =
        case action do
          :steer_request ->
            factory_module.steer(server_id, content, expected_request_id: request_id)

          :inject_request ->
            factory_module.inject(server_id, content, expected_request_id: request_id)
        end

      %{event | response: response}
    else
      {:ok, state} when is_map(state) -> %{event | response: {:error, :missing_server_id}}
      {:error, reason} -> %{event | response: {:error, reason}}
      other -> %{event | response: {:error, other}}
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

  def handle_event(%Event{} = event, :system_config_agent_list_active_agents, _context) do
    %{event | response: Agent.list_active_agents()}
  end

  def handle_event(%Event{} = event, :system_config_mcp_get_endpoint, _context) do
    case event.request do
      %{id: id} ->
        endpoint = MCP.get_mcp_endpoint!(id)
        %{event | response: {:ok, endpoint}}

      other ->
        invalid_request_response(event, other)
    end
  rescue
    Ecto.NoResultsError -> %{event | response: {:error, :not_found}}
  end

  def handle_event(%Event{} = event, :system_config_mcp_change_endpoint, _context) do
    case event.request do
      %{endpoint: endpoint, attrs: attrs} when is_map(attrs) ->
        %{event | response: MCP.change_mcp_endpoint(endpoint, attrs)}

      %{endpoint: endpoint} ->
        %{event | response: MCP.change_mcp_endpoint(endpoint)}

      other ->
        invalid_request_response(event, other)
    end
  end

  def handle_event(%Event{} = event, :system_config_mcp_filter_endpoints, _context) do
    case event.request do
      %{filters: filters, page: page, per_page: per_page} when is_map(filters) ->
        %{event | response: MCP.filter_mcp_endpoints(filters, page: page, per_page: per_page)}

      other ->
        invalid_request_response(event, other)
    end
  end

  def handle_event(%Event{} = event, :system_config_mcp_predefined_catalog, _context) do
    %{event | response: MCP.predefined_catalog()}
  end

  def handle_event(%Event{} = event, action, _context) do
    %{event | response: {:error, {:unsupported_action, action}}}
  end

  # Channels build assigns from JSON (string keys); in-process callers such as
  # the workflow `RunAgent` tool set an atom-keyed `:agent_selection`. Accept both
  # so a selected agent always routes to `Executor.run/2` (direct agent run)
  # rather than falling through to the RAG `Pipeline`.
  defp selected_agent_id(assigns) when is_map(assigns) do
    case Map.get(assigns, "agent_selection") || Map.get(assigns, :agent_selection) do
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

  defp request_id_request(request) when is_map(request) do
    case fetch_key(request, :request_id) do
      {:ok, request_id} when is_binary(request_id) and request_id != "" -> {:ok, request_id}
      _ -> {:error, :missing_request_id}
    end
  end

  defp request_id_request(_), do: {:error, :missing_request_id}

  defp content_request(request) when is_map(request) do
    case fetch_key(request, :content) do
      {:ok, content} when is_binary(content) and content != "" -> {:ok, content}
      _ -> {:error, :missing_content}
    end
  end

  defp content_request(_), do: {:error, :missing_content}

  defp normalize_action_error({:error, {:invalid_request, _} = reason}), do: {:error, reason}
  defp normalize_action_error({:error, reason}), do: {:error, {:action_failed, reason}}
  defp normalize_action_error(other), do: other

  defp dispatch_pipeline(event, incoming) do
    pipeline_opts = Keyword.get(event.opts, :pipeline_opts, [])
    pipeline_module = Keyword.get(event.opts, :pipeline_module, Pipeline)
    executor_module = Keyword.get(event.opts, :executor_module, Executor)
    node_router_mod = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

    # Identity resolution moves to Executor once a generic contract replaces the BO IdentityPlug.
    incoming = identity_plug_mod(event.opts).call(incoming, pipeline_opts)

    # Channels build the actor before IdentityPlug runs, so the resolved
    # person_id must be propagated here. Downstream consumers (workflow
    # triggers via the post-dispatch broadcast, persistence hops) rely on it.
    event = enrich_actor_person(event, incoming.person_id)

    incoming_dims = incoming.metadata |> Map.get("telemetry_dimensions", %{})

    pipeline_opts =
      Keyword.put_new(pipeline_opts, :telemetry_dimensions, incoming_dims)

    outgoing =
      case selected_agent_id(event.assigns) do
        nil ->
          pipeline_module.run(
            incoming,
            pipeline_opts
            |> Keyword.put(:scope, Executor.derive_scope(incoming))
            |> Keyword.put(:event, event)
          )

        selected_id ->
          person_id = incoming.person_id

          team_ids =
            case node_router_mod.dispatch(
                   Event.new(
                     %{person_id: person_id},
                     :engine,
                     actor: event.actor,
                     opts: [action: :get_person],
                     trace_id: event.trace_id
                   )
                 ).response do
              nil -> []
              %{team_ids: ids} when not is_nil(ids) -> ids
              _ -> []
            end

          executor_module.run(incoming,
            agent_id: selected_id,
            scope: Executor.derive_scope(incoming),
            person_id: person_id,
            team_ids: team_ids,
            source_filter: incoming.content_filter,
            skip_permissions: Keyword.get(pipeline_opts, :skip_permissions, false),
            history: Keyword.get(pipeline_opts, :history, %{}),
            telemetry_dimensions: Keyword.get(pipeline_opts, :telemetry_dimensions, %{}),
            event: event
          )
      end

    maybe_dispatch_return_hop(event, incoming, outgoing)
  end

  # Never overwrites an existing actor person_id and never writes nil —
  # a missing person must stay missing (nil is not an identity).
  defp enrich_actor_person(%Event{} = event, nil), do: event

  defp enrich_actor_person(%Event{actor: actor} = event, person_id) when is_map(actor) do
    if Map.get(actor, :person_id) || Map.get(actor, "person_id") do
      event
    else
      %{event | actor: Map.put(actor, :person_id, person_id)}
    end
  end

  defp enrich_actor_person(%Event{} = event, _person_id), do: event

  # This function is a good candidate to go into the NodeRouter for generalization
  defp maybe_dispatch_return_hop(%Event{} = event, %Incoming{} = incoming, %Outgoing{} = outgoing) do
    if delivery_through_channels?(outgoing.provider) do
      node_router_mod = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

      case persist_response_context(node_router_mod, event, incoming, outgoing) do
        {:ok, persisted} ->
          event
          |> schedule_return_hop(enrich_outgoing_with_persistence(outgoing, persisted))

        {:error, _reason} ->
          schedule_return_hop(event, outgoing)
      end
    else
      %{event | response: outgoing}
    end
  end

  defp maybe_dispatch_return_hop(%Event{} = event, _incoming, other),
    do: %{event | response: other}

  defp delivery_through_channels?(provider), do: not is_nil(provider)

  defp schedule_return_hop(%Event{} = event, %Outgoing{} = outgoing) do
    hop = EventHop.new(:channels, :sync, DateTime.utc_now())

    %{
      event
      | request: outgoing,
        response: outgoing,
        next_hop: hop,
        opts: Keyword.put(event.opts, :action, :deliver_outgoing)
    }
  end

  defp persist_response_context(
         node_router_mod,
         %Event{} = event,
         %Incoming{} = incoming,
         %Outgoing{} = outgoing
       ) do
    persist_event =
      Event.new(%{incoming: incoming, metadata: outgoing.metadata}, :engine,
        actor: event.actor,
        opts: [action: :persist_from_incoming],
        trace_id: event.trace_id
      )

    case node_router_mod.dispatch(%{persist_event | assigns: event.assigns}).response do
      :ok -> {:ok, %{}}
      {:ok, persisted} when is_map(persisted) -> {:ok, persisted}
      {:ok, _} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_persist_response, other}}
    end
  end

  defp enrich_outgoing_with_persistence(%Outgoing{} = outgoing, persisted)
       when is_map(persisted) do
    metadata =
      outgoing.metadata
      |> maybe_put_persisted(:conversation_id, Map.get(persisted, :conversation_id))
      |> maybe_put_persisted(:assistant_message_id, Map.get(persisted, :assistant_message_id))

    %{outgoing | metadata: metadata}
  end

  defp maybe_put_persisted(metadata, _key, nil), do: metadata
  defp maybe_put_persisted(metadata, key, value), do: Map.put(metadata, key, value)

  defp guard_error_outgoing(%Incoming{} = incoming) do
    Outgoing.from_pipeline_result(incoming, %{
      answer: ErrorMessage.from_reason(:guard_blocked),
      error_reason: :guard_blocked,
      confidence_score: 0.0,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: true
    })
  end

  defp invalid_request_response(event, other),
    do: %{event | response: {:error, {:invalid_request, other}}}
end
