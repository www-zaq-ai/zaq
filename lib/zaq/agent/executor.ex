defmodule Zaq.Agent.Executor do
  @moduledoc """
  Single execution boundary for all agent runs.

  This module orchestrates the full request lifecycle for both:

  - the default answering configuration (`Zaq.Agent.Answering`) and
  - explicitly selected BO-configured agents.

  Key concerns handled here:

  - Scope derivation (`derive_scope/1`) so requests are routed to the correct
    long-lived Jido server identity (conversation/person/session/anonymous).
  - Agent selection and per-run overrides (for example temporary
    `:system_prompt`).
  - Server orchestration through `Zaq.Agent.ServerManager.ensure_server/2`.
  - Query execution via `Zaq.Agent.Factory.ask_with_config/4` and
    `Zaq.Agent.StreamEvents.consume/3`.
  - User-facing side effects: typing signal (Channels API through
    `Zaq.NodeRouter`) and answering status broadcasts (`Zaq.Agent.Status`).
  - Observability: execution counters, latency/confidence metrics, and
    normalized error classification through `Zaq.Engine.Telemetry`.
  - Output normalization into `Zaq.Engine.Messages.Outgoing` so downstream
    channel adapters receive a consistent payload shape.

  In short, `Executor` is the workflow coordinator; it does not build provider
  specs or runtime tool config itself. Those responsibilities stay in
  `ProviderSpec`/`Factory`, while `ServerManager` owns process lifecycle.
  """

  require Logger

  alias Zaq.Agent

  alias Zaq.Agent.{
    Answering,
    ErrorMessage,
    Factory,
    LogprobsAnalyzer,
    ServerManager,
    StreamEvents
  }

  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Telemetry
  alias Zaq.Event
  alias Zaq.Utils.DateUtils

  @doc """
  Derives a stable scope string from an incoming message used to key the Jido agent server.

  Format: `"channel:type:identity"` where channel is the normalized provider and identity is
  `person_id`, `session_id`, or `"anonymous"`.

  Priority order:
  1. `:web` provider + `metadata.conversation_id` — `"bo:conv:<id>"` (BO per-conversation isolation)
  2. `person_id` — `"<channel>:person:<person_id>"` when present
  3. `metadata.session_id` — `"bo:session:<session_id>"` when `person_id` is nil and session ID is a non-empty string
  4. `"anonymous"` — fallback for all other cases

  ## Examples

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :web}
      iex> Zaq.Agent.Executor.derive_scope(%{base | metadata: %{conversation_id: "conv-42"}})
      "bo:conv:conv-42"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(%{base | person_id: 7})
      "test:person:7"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(%{base | person_id: nil, metadata: %{session_id: "sess_abc"}})
      "bo:session:sess_abc"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(%{base | person_id: nil, metadata: %{}})
      "anonymous"

  """
  @spec derive_scope(Incoming.t()) :: String.t()
  def derive_scope(%Incoming{provider: :web, metadata: %{conversation_id: id}})
      when is_binary(id) and id != "",
      do: "bo:conv:#{id}"

  def derive_scope(%Incoming{person_id: person_id, provider: provider})
      when not is_nil(person_id),
      do: "#{normalize_provider(provider)}:person:#{person_id}"

  def derive_scope(%Incoming{metadata: %{session_id: sid}})
      when is_binary(sid) and sid != "",
      do: "bo:session:#{sid}"

  def derive_scope(_), do: "anonymous"

  @doc """
  Runs the full agent execution pipeline for an incoming message.

  Loads the configured agent (or the default answering agent when no selected
  agent opt is given), ensures its Jido server is running, sends a typing
  indicator, submits the question via `Factory.ask_with_config/4`, consumes
  stream events for realtime updates and trace capture, then records telemetry
  and returns a normalized `Outgoing.t()`.

  On any `{:error, reason}` in the pipeline the error is logged, an error telemetry
  event is emitted, and a safe fallback `Outgoing.t()` is returned — this function
  never raises.

  ## Options

  - `:agent_id` — integer ID of the configured agent to use; omit for the default answering agent
  - `:agent_name` — configured agent name to use when `:agent_id` is absent
  - `:scope` — explicit server scope string; derived from `derive_scope/1` when absent on the answering path
  - `:question` — override the question text; defaults to `incoming.content`
  - `:system_prompt` — override the agent's `job` field for this run only
  - `:person_id` — passed into the retrieval context for permission scoping
  - `:team_ids` — list of team IDs passed into the retrieval context
  - `:event` — the dispatching `%Zaq.Event{}`; its `actor` is exposed to tools via the tool context
  - `:agent_module`, `:server_manager_module`, `:factory_module`, `:answering_module`, `:node_router` — injectable dependencies for testing
  """
  @spec run(Incoming.t(), keyword()) :: Outgoing.t()
  def run(%Incoming{} = incoming, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    agent_module = Keyword.get(opts, :agent_module, Agent)
    server_manager_module = Keyword.get(opts, :server_manager_module, ServerManager)
    factory_module = Keyword.get(opts, :factory_module, Factory)
    opts = ensure_scope_for_answering_path(opts, incoming)
    selected_agent_result = load_selected_agent(opts, agent_module, factory_module)
    dims = telemetry_dimensions(incoming, selected_agent_result)

    :ok = Telemetry.record("qa.message.count", 1, dims)
    :ok = Telemetry.record("qa.custom_agent.execution.start", 1, dims)

    question =
      opts
      |> Keyword.get(:question, incoming.content)
      |> timestamp_question()

    result =
      with {:ok, configured_agent} <- selected_agent_result,
           configured_agent <- apply_system_prompt_override(configured_agent, opts),
           {:ok, server_id} <-
             ensure_agent_server(server_manager_module, configured_agent, opts),
           _ <-
             Event.new(%{provider: incoming.provider, channel_id: incoming.channel_id}, :channels,
               opts: [action: :send_typing],
               type: :async
             )
             |> node_router(opts).dispatch(),
           status_result <-
             status_mod(opts).broadcast(
               incoming,
               :answering,
               "Formulating your answer…",
               node_router(opts)
             ),
           %Incoming{} = incoming <- normalize_status_result(status_result, incoming),
           {:ok, %{request: _request, events: events}} <-
             factory_module.ask_with_config(server_id, question, configured_agent,
               tool_context: %{
                 incoming: incoming,
                 person_id: Keyword.get(opts, :person_id),
                 team_ids: Keyword.get(opts, :team_ids, []),
                 source_filter: Keyword.get(opts, :source_filter),
                 skip_permissions: Keyword.get(opts, :skip_permissions, false),
                 actor: event_actor(opts),
                 node_router: Keyword.get(opts, :node_router, Zaq.NodeRouter)
               }
             ),
           {:ok, stream_result} <-
             StreamEvents.consume(events, incoming,
               started_at: started_at,
               server_id: server_id,
               agent: configured_agent,
               node_router: node_router(opts),
               status_module: status_mod(opts)
             ) do
        incoming = stream_result.incoming
        answer = %{result: stream_result.answer, usage: stream_result.usage}

        confidence =
          LogprobsAnalyzer.confidence_from_metadata_or_nil(%{
            logprobs: LogprobsAnalyzer.from_response(answer)
          })

        result = success_result(answer, configured_agent, confidence, stream_result)
        :ok = record_success_telemetry(result, dims)
        Outgoing.from_pipeline_result(incoming, result)
      else
        {:error, %ReqLLM.Error.API.Stream{} = reason, partial} ->
          if suppress_stream_error?(incoming, partial) do
            # Stream error after tokens were already delivered — the answer is visible.
            # Suppress the error bubble so we don't overlay a complete streamed response.
            Logger.warning(
              "Stream ended with error after content was delivered (suppressing error bubble): #{inspect(reason)}"
            )

            record_execution_error(dims, reason)
            Outgoing.from_pipeline_result(incoming, suppressed_stream_error_result(reason))
          else
            # Stream failed before any content reached the user (e.g. budget/rate
            # limit on the first token). Surface the error instead of an empty bubble.
            surface_execution_error(incoming, reason, dims, selected_agent_result)
          end

        {:error, reason, _partial} ->
          surface_execution_error(incoming, reason, dims, selected_agent_result)

        {:error, reason} ->
          surface_execution_error(incoming, reason, dims, selected_agent_result)
      end

    result
  end

  # Suppress only when a streaming surface exists AND answer content was actually
  # delivered to the user. The mere presence of a status placeholder is not proof
  # that any tokens reached the user.
  defp suppress_stream_error?(%Incoming{} = incoming, partial) do
    not is_nil(get_in(incoming.metadata, [:status_message_id])) and content_delivered?(partial)
  end

  defp content_delivered?(%{answer: answer}) when is_binary(answer),
    do: String.trim(answer) != ""

  defp content_delivered?(_), do: false

  defp surface_execution_error(incoming, reason, dims, selected_agent_result) do
    Logger.error("Configured agent execution failed: #{inspect(reason)}")
    record_execution_error(dims, reason)

    Outgoing.from_pipeline_result(
      incoming,
      error_result(reason, maybe_configured_agent(selected_agent_result))
    )
  end

  defp record_execution_error(dims, reason) do
    :ok =
      Telemetry.record(
        "qa.custom_agent.execution.error",
        1,
        Map.put(dims, :error_type, error_type(reason))
      )

    :ok
  end

  defp ensure_agent_server(server_manager_module, configured_agent, opts) do
    server_id = "#{configured_agent.name}:#{Keyword.get(opts, :scope, "anonymous")}"
    server_manager_module.ensure_server(configured_agent, server_id)
  end

  defp load_selected_agent(opts, agent_module, _factory_module) do
    answering_module = Keyword.get(opts, :answering_module, Answering)

    cond do
      agent_id = Keyword.get(opts, :agent_id) ->
        agent_module.get_active_agent(agent_id)

      agent_name = Keyword.get(opts, :agent_name) ->
        agent_module.get_active_agent_by_name(agent_name)

      true ->
        {:ok, answering_module.answering_configured_agent()}
    end
  end

  defp ensure_scope_for_answering_path(opts, incoming) do
    if is_nil(Keyword.get(opts, :scope)),
      do: Keyword.put(opts, :scope, derive_scope(incoming)),
      else: opts
  end

  @doc false
  def normalize_provider(:web), do: "bo"

  def normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> String.replace(":", "_")

  def normalize_provider(provider) when is_binary(provider),
    do: String.replace(provider, ":", "_")

  defp apply_system_prompt_override(configured_agent, opts) do
    case Keyword.get(opts, :system_prompt) do
      prompt when is_binary(prompt) and prompt != "" -> %{configured_agent | job: prompt}
      _ -> configured_agent
    end
  end

  defp success_result(answer, configured_agent, confidence, stream_result) do
    answer_text = normalize_answer(answer)
    measurements = Map.get(stream_result, :measurements, %{}) || %{}

    %{
      answer: answer_text,
      confidence_score: confidence,
      latency_ms: measurement_value(measurements, "latency_ms"),
      prompt_tokens: measurement_value(measurements, "input_tokens"),
      completion_tokens: measurement_value(measurements, "output_tokens"),
      total_tokens: measurement_value(measurements, "total_tokens"),
      error: false,
      configured_agent_id: configured_agent.id,
      configured_agent_name: configured_agent.name,
      agent: stream_result.agent,
      model: stream_result.model,
      measurements: measurements,
      termination_reason: stream_result.termination_reason,
      tool_calls: stream_result.tool_calls,
      trace: stream_result.trace,
      sources: []
    }
  end

  defp suppressed_stream_error_result(_reason) do
    %{
      answer: "",
      confidence_score: nil,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: false,
      suppressed: true,
      sources: []
    }
  end

  defp error_result(reason, _configured_agent) do
    %{
      answer:
        ErrorMessage.from_reason(
          reason,
          "Sorry, something went wrong while executing the selected agent."
        ),
      error_type: ErrorMessage.error_type_for(reason),
      confidence_score: nil,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: true,
      reason: inspect(reason),
      sources: []
    }
  end

  defp maybe_configured_agent({:ok, agent}), do: agent
  defp maybe_configured_agent(_), do: nil

  defp normalize_answer(%{result: result}), do: normalize_answer(result)
  defp normalize_answer(%{answer: answer}) when is_binary(answer), do: answer
  defp normalize_answer(answer) when is_binary(answer), do: answer
  defp normalize_answer(other), do: inspect(other)

  defp measurement_value(measurements, key) when is_map(measurements) do
    Map.get(measurements, key) || Map.get(measurements, safe_existing_atom(key))
  end

  # Measurement maps may use string or atom keys. Never mint new atoms from
  # runtime data (atom-exhaustion DoS) — only resolve atoms that already exist.
  defp safe_existing_atom(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> nil
  end

  defp record_success_telemetry(result, dims) do
    :ok = Telemetry.record("qa.custom_agent.execution.complete", 1, dims)
    :ok = Telemetry.record("qa.answer.count", 1, dims)

    if is_integer(result.latency_ms),
      do: Telemetry.record("qa.answer.latency_ms", result.latency_ms, dims),
      else: :ok

    :ok = record_token_telemetry(result, dims)

    if is_number(result.confidence_score) do
      :ok = Telemetry.record("qa.answer.confidence", result.confidence_score, dims)

      bucket =
        cond do
          result.confidence_score >= 0.9 -> "qa.answer.confidence.bucket.gt_90"
          result.confidence_score >= 0.7 -> "qa.answer.confidence.bucket.gt_70"
          true -> "qa.answer.confidence.bucket.lt_70"
        end

      Telemetry.record(bucket, 1, dims)
    else
      :ok
    end
  end

  defp record_token_telemetry(result, dims) when is_map(result) do
    :ok =
      maybe_record_token_metric(
        "qa.tokens.prompt",
        Map.get(result, :prompt_tokens),
        dims
      )

    :ok =
      maybe_record_token_metric(
        "qa.tokens.completion",
        Map.get(result, :completion_tokens),
        dims
      )

    maybe_record_token_metric(
      "qa.tokens.total",
      Map.get(result, :total_tokens),
      dims
    )
  end

  defp record_token_telemetry(_measurements, _dims), do: :ok

  defp maybe_record_token_metric(_metric_key, value, _dims) when not is_integer(value), do: :ok

  defp maybe_record_token_metric(metric_key, value, dims),
    do: Telemetry.record(metric_key, value, dims)

  defp normalize_status_result(%Incoming{} = updated_incoming, _fallback_incoming),
    do: updated_incoming

  defp normalize_status_result(_other, %Incoming{} = fallback_incoming), do: fallback_incoming

  defp telemetry_dimensions(incoming, selected_agent_result) do
    base = incoming_telemetry_dimensions(incoming)

    runtime =
      case selected_agent_result do
        {:ok, configured_agent} ->
          %{
            execution_path: "custom_agent",
            configured_agent_id: configured_agent.id,
            configured_agent_name: configured_agent.name
          }

        _ ->
          %{execution_path: "custom_agent"}
      end

    Map.merge(base, runtime)
  end

  defp incoming_telemetry_dimensions(%Incoming{} = incoming) do
    incoming.metadata
    |> Map.get("telemetry_dimensions", %{})
    |> Enum.reduce(%{}, fn
      {key, value}, acc when is_binary(key) ->
        try do
          Map.put(acc, String.to_existing_atom(key), value)
        rescue
          ArgumentError -> acc
        end

      {key, value}, acc when is_atom(key) ->
        Map.put(acc, key, value)

      _, acc ->
        acc
    end)
  end

  defp error_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type(%{__struct__: mod}), do: inspect(mod)
  defp error_type(_), do: "unknown"

  # The actor travels on the dispatching %Zaq.Event{}; expose it to tools so
  # they see the same identity shape as workflow steps (StepRunner).
  defp event_actor(opts) do
    case Keyword.get(opts, :event) do
      %Event{actor: actor} -> actor
      _ -> nil
    end
  end

  defp node_router(opts) do
    Keyword.get(
      opts,
      :node_router,
      Application.get_env(:zaq, :pipeline_node_router_module, Zaq.NodeRouter)
    )
  end

  defp timestamp_question(content) when is_binary(content) do
    ts = DateUtils.format_ts(DateTime.utc_now())
    "[#{ts}] #{content}"
  end

  defp timestamp_question(content), do: content

  defp status_mod(opts) do
    Keyword.get(opts, :status_module, Zaq.Agent.Status)
  end
end
