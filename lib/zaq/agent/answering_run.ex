defmodule Zaq.Agent.AnsweringRun do
  @moduledoc """
  Streaming ReAct answering run for the chat transport.

  Runs a ReAct turn against the default answering agent, grounding on the
  knowledge base via `search_knowledge_base` / `knowledge_base_overview`.
  `Jido.AI`'s ReAct `ToolSelection.select_base_or_override/2` *replaces* the
  agent's startup tool registry with the per-run `:tools` override, so the
  answering tools are re-included here — otherwise the agent would lose
  retrieval.

  ## Streaming

  This module does NOT consume the stream itself. It builds the jido_ai request
  (`build_request/3`), hands the caller the raw event enumerable
  (`stream_events/1`), and classifies each event (`classify_event/1`). The
  caller folds that stream while threading its `Plug.Conn`, so each `:llm_delta`
  content token is forwarded the instant it arrives — real token streaming, not
  a buffered single delta.

  `@frontend_tool_modules` is the injection point for display-only tools the
  model could emit for the client to render; none are registered.
  """

  require Logger

  alias Zaq.Agent.{Answering, Factory, ServerManager}
  alias Zaq.Agent.Tools.{KnowledgeBaseOverview, SearchKnowledgeBase}
  alias Zaq.Engine.Messages.Incoming

  @ask_timeout 320_000
  @stream_timeout_ms 320_000

  # Tight iteration cap: the agent should search the KB once or twice, then
  # answer. A high cap lets a confused model loop on search_knowledge_base
  # forever and exhaust the run without ever answering.
  @max_iterations 5

  # Display-only frontend tools the model may emit for the client to render
  # (ZAQ executes nothing). None registered.
  @frontend_tool_modules %{}

  @answering_tools [SearchKnowledgeBase, KnowledgeBaseOverview]

  @max_iter_sentinel "Maximum iterations reached"

  @type tool_call :: %{id: String.t(), name: String.t(), arguments: map() | String.t()}

  @type classified ::
          {:text_delta, String.t()}
          | {:tool_call, tool_call()}
          | {:done, String.t()}
          | {:error, term()}
          | :ignore

  @doc """
  Builds a jido_ai ReAct request and returns its event enumerable.

  Returns `{:ok, events}` — the jido_ai `%Event{}` stream the caller folds (same
  contract `Zaq.Agent.StreamEvents.consume/3` consumes) — or `{:error, reason}`.
  `frontend_tool_names` is the subset of registered display tools to inject;
  pass `[]` for a plain answering turn (none are registered). `opts` accepts
  `:person_id`, `:team_ids`, `:source_filter`, `:skip_permissions`, `:scope`.
  """
  @spec build_request(Incoming.t(), [String.t()], keyword()) ::
          {:ok, Enumerable.t()} | {:error, term()}
  def build_request(%Incoming{} = incoming, frontend_tool_names, opts \\ []) do
    configured_agent = Answering.answering_configured_agent()
    scope = Keyword.get(opts, :scope, "anonymous")
    server_id = "#{configured_agent.name}:#{scope}"

    injected_tools =
      frontend_tool_names
      |> Enum.flat_map(fn name ->
        case Map.fetch(@frontend_tool_modules, name) do
          {:ok, module} -> [module]
          :error -> []
        end
      end)
      |> Kernel.++(@answering_tools)
      |> Enum.uniq()

    with {:ok, server_id} <- ServerManager.ensure_server(configured_agent, server_id),
         {:ok, %{events: events}} <-
           Factory.ask_with_config(server_id, incoming.content, configured_agent,
             tools: injected_tools,
             stream_to: {:pid, self()},
             max_iterations: @max_iterations,
             timeout: @ask_timeout,
             stream_timeout_ms: @stream_timeout_ms,
             tool_context: %{
               incoming: incoming,
               person_id: Keyword.get(opts, :person_id),
               team_ids: Keyword.get(opts, :team_ids, []),
               source_filter: Keyword.get(opts, :source_filter),
               # Anonymous transport (person_id=nil): honor the SAME permission
               # filtering as the plain chat path (default FALSE) — retrieval
               # surfaces only docs tagged `public`. Never blanket-bypass for an
               # unauthenticated transport; `:skip_permissions` stays opt-in.
               skip_permissions: Keyword.get(opts, :skip_permissions, false),
               node_router: Zaq.NodeRouter
             }
           ) do
      {:ok, events}
    end
  end

  @doc """
  Classifies a single jido_ai stream event into a transport-facing instruction.

  - `{:text_delta, delta}` — a streamed answer token to forward as
    `TEXT_MESSAGE_CONTENT`.
  - `{:tool_call, %{id, name, arguments}}` — a frontend (display) tool call to
    forward as a `TOOL_CALL_*` trio.
  - `{:done, final_text}` — the run completed; `final_text` is the full answer
    (a fallback for when nothing streamed).
  - `{:error, reason}` — the run failed/cancelled.
  - `:ignore` — internal event with no transport surface (e.g. retrieval tool
    calls, reasoning deltas, tool completions).
  """
  @spec classify_event(term()) :: classified()
  def classify_event(event) do
    case kind(event) do
      :llm_delta ->
        data = data(event)
        delta = data_get(data, :delta)

        if is_binary(delta) and delta != "" and content_chunk?(data_get(data, :chunk_type)) do
          {:text_delta, delta}
        else
          :ignore
        end

      :tool_started ->
        classify_tool_started(event)

      :request_completed ->
        {:done, data(event) |> data_get(:result) |> normalize_text()}

      :request_failed ->
        {:error, data(event) |> data_get(:error) || :react_failed}

      :request_cancelled ->
        {:error, :react_cancelled}

      _ ->
        :ignore
    end
  end

  defp classify_tool_started(event) do
    data = data(event)
    name = (field(event, :tool_name) || data_get(data, :tool_name)) |> to_string()

    if Map.has_key?(@frontend_tool_modules, name) do
      {:tool_call,
       %{
         id: (field(event, :tool_call_id) || data_get(data, :tool_call_id) || field(event, :id))
             |> to_string(),
         name: name,
         arguments: data_get(data, :arguments) || %{}
       }}
    else
      :ignore
    end
  end

  @doc """
  Retrieved chunks from a `search_knowledge_base` tool completion (for
  citations). Returns `[]` for any other event. Each chunk carries `:source`
  and `:document_id`.
  """
  @spec extract_chunks(term()) :: [map()]
  def extract_chunks(event) do
    if kind(event) == :tool_completed do
      case event |> data() |> data_get(:result) do
        %{} = result -> result |> data_get(:chunks) |> List.wrap()
        _ -> []
      end
    else
      []
    end
  end

  @doc """
  Fallback answer text for the no-stream case: when the model exhausted its
  iterations after making tool calls, the raw "Maximum iterations reached"
  sentinel is a poor user-facing answer — replace it with a short ack.
  """
  @spec finalize_text(String.t(), [tool_call()]) :: String.t()
  def finalize_text(text, [_ | _]) when is_binary(text) do
    if String.contains?(text, @max_iter_sentinel) do
      "Voici le récapitulatif demandé."
    else
      text
    end
  end

  def finalize_text(text, _tool_calls), do: text

  defp content_chunk?(:content), do: true
  defp content_chunk?("content"), do: true
  defp content_chunk?(_), do: false

  defp normalize_text(text) when is_binary(text), do: text
  defp normalize_text(nil), do: ""
  defp normalize_text(other), do: to_string(other)

  defp kind(event), do: field(event, :kind)
  defp data(event), do: field(event, :data) || %{}

  defp field(%module{} = struct, key) when is_atom(module), do: Map.get(struct, key)
  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp field(_, _), do: nil

  defp data_get(data, key), do: field(data, key)
end
