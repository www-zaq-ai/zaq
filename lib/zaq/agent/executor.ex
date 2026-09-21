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
  - Actor-bound server orchestration through `Zaq.Agent.ServerManager.ensure_server/4`.
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
  alias Zaq.Contracts.Record

  alias Zaq.Agent.{
    Answering,
    ErrorMessage,
    Factory,
    LogprobsAnalyzer,
    OpaqueAliases,
    ServerManager,
    StreamEvents
  }

  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Engine.Telemetry
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Identity.ExecutionActor
  alias Zaq.Utils.DateUtils

  @llm_usage_attribution "v1"

  @doc """
  Derives a stable scope string from an incoming message and actor used to key the Jido agent server.

  Format: `"channel:type:identity"` where channel is the normalized provider and identity is
  `person.id`, `session_id`, or `"anonymous"`.

  Priority order:
  1. `metadata.run_id` + `metadata.step_index` — `"workflow:run:<run_id>:step:<step_index>"`
     (per-step isolation: each `run_agent` step in a run gets its own agent server, so two
     `run_agent` steps in the same run never contend on one shared server).
  2. `metadata.run_id` (no step index) — `"workflow:run:<run_id>"` (per-run isolation for
     node-internal callers such as `RunAgent`; overrides identity-derived scopes so each
     workflow run gets its own agent server). The caller only carries the run id (and
     step index) as data — this function owns the scope policy.
  3. `:web` provider + `metadata.conversation_id` — `"scope:bo:conv:<id>"` (BO per-conversation isolation)
  4. `actor.person.id` — `"scope:<encoded_channel>:person:<person_id>"` when present
  5. `metadata.session_id` — `"bo:session:<session_id>"` when actor person is nil and session ID is a non-empty string
  6. `"anonymous"` — fallback for all other cases

  ## Examples

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :web}
      iex> Zaq.Agent.Executor.derive_scope(%{base | metadata: %{conversation_id: "conv-42"}})
      "scope:bo:conv:conv-42"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(base, %{person: %{id: 7}})
      "scope:test:person:7"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(%{base | person: nil, metadata: %{session_id: "sess_abc"}})
      "bo:session:sess_abc"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(%{base | person: nil, metadata: %{}})
      "anonymous"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(%{base | person: %{id: 9}, metadata: %{run_id: "r1"}})
      "workflow:run:r1"

      iex> alias Zaq.Engine.Messages.Incoming
      iex> base = %Incoming{content: "hi", channel_id: "c1", provider: :test}
      iex> Zaq.Agent.Executor.derive_scope(%{base | metadata: %{run_id: "r1", step_index: 2}})
      "workflow:run:r1:step:2"

  """
  @spec derive_scope(Incoming.t()) :: String.t()
  def derive_scope(%Incoming{} = incoming),
    do: derive_scope(incoming, ActorNormalizer.from_incoming(nil, incoming))

  @spec derive_scope(Incoming.t(), map() | nil) :: String.t()
  def derive_scope(%Incoming{metadata: %{run_id: run_id, step_index: step_index}}, _actor)
      when is_binary(run_id) and run_id != "" and is_integer(step_index),
      do: "workflow:run:#{run_id}:step:#{step_index}"

  def derive_scope(%Incoming{metadata: %{run_id: run_id}}, _actor)
      when is_binary(run_id) and run_id != "",
      do: "workflow:run:#{run_id}"

  def derive_scope(%Incoming{provider: :web, metadata: %{conversation_id: id}}, _actor)
      when is_binary(id) and id != "",
      do: scoped_id(:web, :conv, id)

  def derive_scope(%Incoming{provider: provider} = incoming, actor) do
    case ActorNormalizer.person_id(actor) do
      nil -> derive_scope_without_person(incoming)
      person_id -> scoped_id(provider, :person, person_id)
    end
  end

  defp derive_scope_without_person(%Incoming{metadata: %{session_id: sid}})
       when is_binary(sid) and sid != "",
       do: "bo:session:#{sid}"

  defp derive_scope_without_person(_), do: "anonymous"

  @doc """
  Runs the full agent execution pipeline for an incoming message.

  Loads the configured agent (or the default answering agent when no `:agent_id` opt is
  given), ensures its Jido server is running, sends a typing indicator, submits the
  question via `Factory.ask_with_config/4`, consumes stream events for realtime
  updates and trace capture, then records telemetry and returns a normalized
  `Outgoing.t()`.

  On any `{:error, reason}` in the pipeline the error is logged, an error telemetry
  event is emitted, and a safe fallback `Outgoing.t()` is returned — this function
  never raises.

  ## Options

  - `:agent_id` — integer ID of the configured agent to use; omit for the default answering agent
  - `:scope` — explicit server scope string; derived from `derive_scope/1` when absent on the answering path
  - `:question` — override the question text; defaults to `incoming.content`
  - `:system_prompt` — override the agent's `job` field for this run only
  - `:person_id` — passed into the retrieval context for permission scoping
  - `:team_ids` — list of team IDs passed into the retrieval context
  - `:context` — a pre-built `Jido.AI.Context` used as the agent's cold-start context (e.g. `RunAgent`'s step turns); when present the server spawns with it and skips history loading. Only consumed on cold start
  - `:event` — the dispatching `%Zaq.Event{}`; its validated actor binds the server lifecycle and is exposed to tools. Without an event actor, a trusted Incoming Person is required; missing identity never becomes anonymous implicitly
  - `:agent_module`, `:server_manager_module`, `:factory_module`, `:answering_module`, `:node_router` — injectable dependencies for testing
  """
  @spec run(Incoming.t(), keyword()) :: Outgoing.t()
  def run(%Incoming{} = incoming, opts \\ []) do
    started_at = System.monotonic_time(:millisecond)
    agent_module = Keyword.get(opts, :agent_module, Agent)
    server_manager_module = Keyword.get(opts, :server_manager_module, ServerManager)
    factory_module = Keyword.get(opts, :factory_module, Factory)
    actor_result = execution_actor(opts, incoming)
    selected_agent_result = load_selected_agent(opts, agent_module, factory_module)
    dims = telemetry_dimensions(incoming, selected_agent_result)

    :ok = Telemetry.record("qa.message.count", 1, dims)
    :ok = Telemetry.record("qa.custom_agent.execution.start", 1, dims)

    question = Keyword.get(opts, :question, incoming.content)
    execution_opts = effective_execution_opts(opts, incoming, actor_result)

    result =
      with {:ok, actor} <- actor_result,
           {:ok, configured_agent} <- selected_agent_result,
           configured_agent <- apply_system_prompt_override(configured_agent, execution_opts),
           server_id <- agent_server_id(configured_agent, execution_opts),
           {:ok, server_ref} <-
             ensure_agent_server(
               server_manager_module,
               configured_agent,
               server_id,
               execution_opts,
               actor
             ),
           question <-
             question
             |> append_attachments(incoming.attachments, server_id)
             |> timestamp_question(),
           _ <-
             Event.new(
               %{provider: incoming.provider, channel_id: incoming.channel_id},
               :channels,
               opts: [action: :send_typing],
               type: :async
             )
             |> node_router(execution_opts).dispatch(),
           status_result <-
             status_mod(execution_opts).broadcast(
               incoming,
               :answering,
               "Formulating your answer…",
               node_router(execution_opts)
             ),
           %Incoming{} = incoming <- normalize_status_result(status_result, incoming),
           {:ok, %{request: _request, events: events}} <-
             factory_module.ask_with_config(server_ref, question, configured_agent,
               tool_context: %{
                 incoming: incoming,
                 person_id: Keyword.get(execution_opts, :person_id),
                 team_ids: Keyword.get(execution_opts, :team_ids, []),
                 source_filter: Keyword.get(execution_opts, :source_filter),
                 skip_permissions: Keyword.get(execution_opts, :skip_permissions, false),
                 actor: actor,
                 node_router: Keyword.get(execution_opts, :node_router, Zaq.NodeRouter)
               }
             ),
           {:ok, stream_result} <-
             StreamEvents.consume(events, incoming,
               started_at: started_at,
               server_id: server_ref,
               agent: configured_agent,
               node_router: node_router(execution_opts),
               status_module: status_mod(execution_opts)
             ) do
        incoming = stream_result.incoming
        answer = %{result: stream_result.answer, usage: stream_result.usage}

        confidence =
          LogprobsAnalyzer.confidence_from_metadata_or_nil(%{
            logprobs: LogprobsAnalyzer.from_response(answer)
          })

        result = success_result(answer, configured_agent, confidence, stream_result)
        :ok = record_success_telemetry(result, dims, actor, incoming, configured_agent)
        Outgoing.from_pipeline_result(incoming, result)
      else
        {:error, %ReqLLM.Error.API.Stream{} = reason, partial} ->
          :ok =
            record_partial_llm_telemetry(
              partial,
              dims,
              telemetry_actor(actor_result),
              incoming,
              selected_agent_result
            )

          handle_stream_error(
            incoming,
            reason,
            partial,
            dims,
            selected_agent_result,
            execution_opts,
            server_manager_module
          )

        {:error, reason, partial} ->
          :ok =
            record_partial_llm_telemetry(
              partial,
              dims,
              telemetry_actor(actor_result),
              incoming,
              selected_agent_result
            )

          surface_execution_error(
            incoming,
            reason,
            dims,
            selected_agent_result,
            execution_opts,
            server_manager_module
          )

        {:error, reason} ->
          surface_execution_error(
            incoming,
            reason,
            dims,
            selected_agent_result,
            execution_opts,
            server_manager_module
          )
      end

    result
  end

  # A streaming error after tokens were already delivered means the answer is
  # visible; suppress the error bubble so we don't overlay a complete response.
  # Otherwise (failed before any content — e.g. budget/rate limit on the first
  # token) surface the error instead of an empty bubble.
  defp handle_stream_error(
         incoming,
         reason,
         partial,
         dims,
         selected_agent_result,
         opts,
         server_manager_module
       ) do
    if suppress_stream_error?(incoming, partial) do
      Logger.warning(
        "Stream ended with error after content was delivered (suppressing error bubble): #{inspect(reason)}"
      )

      record_execution_error(dims, reason)
      Outgoing.from_pipeline_result(incoming, suppressed_stream_error_result(reason))
    else
      surface_execution_error(
        incoming,
        reason,
        dims,
        selected_agent_result,
        opts,
        server_manager_module
      )
    end
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

  defp surface_execution_error(
         incoming,
         reason,
         dims,
         selected_agent_result,
         opts,
         server_manager_module
       ) do
    reason =
      enrich_provider_authentication_error(
        reason,
        selected_agent_result,
        opts,
        server_manager_module
      )

    Logger.error("Configured agent execution failed: #{inspect(reason)}")
    record_execution_error(dims, reason)

    Outgoing.from_pipeline_result(
      incoming,
      error_result(reason, maybe_configured_agent(selected_agent_result))
    )
  end

  defp enrich_provider_authentication_error(
         reason,
         {:ok, configured_agent},
         opts,
         server_manager_module
       ) do
    if function_exported?(server_manager_module, :credential_dependency, 1) do
      configured_agent
      |> agent_server_id(opts)
      |> server_manager_module.credential_dependency()
      |> then(&ErrorMessage.with_credential_owner(reason, owner_type(&1)))
    else
      reason
    end
  catch
    :exit, _reason -> reason
  end

  defp enrich_provider_authentication_error(reason, _selected, _opts, _server_manager),
    do: reason

  defp owner_type(%{owner_type: owner_type}), do: owner_type
  defp owner_type(_dependency), do: nil

  defp record_execution_error(dims, reason) do
    :ok =
      Telemetry.record(
        "qa.custom_agent.execution.error",
        1,
        Map.put(dims, :error_type, error_type(reason))
      )

    :ok
  end

  defp agent_server_id(configured_agent, opts) do
    "#{configured_agent.name}:#{Keyword.get(opts, :scope, "anonymous")}"
  end

  defp ensure_agent_server(server_manager_module, configured_agent, server_id, opts, actor) do
    server_manager_module.ensure_server(configured_agent, server_id, Keyword.get(opts, :context),
      actor: actor
    )
  end

  defp load_selected_agent(opts, agent_module, _factory_module) do
    answering_module = Keyword.get(opts, :answering_module, Answering)

    case Keyword.get(opts, :agent_id) do
      nil -> {:ok, answering_module.answering_configured_agent()}
      agent_id -> agent_module.get_active_agent(agent_id)
    end
  end

  defp ensure_scope_for_answering_path(opts, incoming, actor) do
    if is_nil(Keyword.get(opts, :scope)),
      do: Keyword.put(opts, :scope, derive_scope(incoming, actor)),
      else: opts
  end

  defp effective_execution_opts(opts, incoming, {:ok, actor}),
    do: ensure_scope_for_answering_path(opts, incoming, actor)

  defp effective_execution_opts(opts, _incoming, _actor_result), do: opts

  defp execution_actor(opts, incoming) do
    case event_actor(opts) do
      nil -> incoming_actor(incoming)
      actor -> ExecutionActor.validate(actor)
    end
  end

  defp incoming_actor(%Incoming{person: nil}), do: ExecutionActor.validate(nil)

  defp incoming_actor(%Incoming{} = incoming) do
    # Check raw declarations before ActorNormalizer can discard conflicting aliases.
    with {:ok, actor} <- ExecutionActor.validate(%{person: incoming.person}) do
      {:ok, ActorNormalizer.from_incoming(actor, incoming)}
    end
  end

  @doc false
  def normalize_provider(:web), do: "bo"

  def normalize_provider(provider) when is_atom(provider),
    do: Atom.to_string(provider)

  def normalize_provider(provider) when is_binary(provider),
    do: provider

  defp scoped_id(provider, kind, id) when kind in [:conv, :person] do
    "scope:#{encode_scope_segment(normalize_provider(provider))}:#{kind}:#{id}"
  end

  defp encode_scope_segment(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

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
      llm_calls: Map.get(stream_result, :llm_calls, []),
      trace: stream_result.trace,
      trace_artifacts: Map.get(stream_result, :trace_artifacts, []),
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
    public_reason = ErrorMessage.public_reason_for(reason)

    %{
      answer:
        ErrorMessage.from_reason(
          reason,
          "Sorry, something went wrong while executing the selected agent."
        ),
      error_type: ErrorMessage.error_type_for(reason),
      error_recovery: ErrorMessage.recovery_for(reason),
      error_retryable: ErrorMessage.retryable?(reason),
      confidence_score: nil,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: true,
      reason: inspect(public_reason),
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

  defp record_success_telemetry(result, dims, actor, incoming, configured_agent) do
    :ok = Telemetry.record("qa.custom_agent.execution.complete", 1, dims)
    :ok = Telemetry.record("qa.answer.count", 1, dims)

    if is_integer(result.latency_ms),
      do: Telemetry.record("qa.answer.latency_ms", result.latency_ms, dims),
      else: :ok

    :ok = record_token_telemetry(result, token_telemetry_dimensions(result, dims))
    :ok = record_llm_call_telemetry(result, dims, actor, incoming, configured_agent)

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

  defp maybe_record_token_metric(_metric_key, value, _dims) when not is_integer(value), do: :ok

  defp maybe_record_token_metric(metric_key, value, dims),
    do: Telemetry.record(metric_key, value, dims)

  defp record_llm_call_telemetry(result, dims, actor, incoming, configured_agent) do
    configured_provider = configured_provider(configured_agent)
    dims = Map.put(dims, :llm_usage_attribution, @llm_usage_attribution)

    result
    |> Map.get(:llm_calls, [])
    |> Enum.each(fn call ->
      call_dims = llm_call_dimensions(dims, call, actor, incoming, configured_provider)

      :ok = Telemetry.record("qa.llm.call.count", 1, call_dims)
      :ok = maybe_record_token_metric("qa.llm.tokens.prompt", call[:input_tokens], call_dims)
      :ok = maybe_record_token_metric("qa.llm.tokens.completion", call[:output_tokens], call_dims)
      :ok = maybe_record_token_metric("qa.llm.tokens.total", call[:total_tokens], call_dims)
    end)

    :ok
  end

  defp token_telemetry_dimensions(%{llm_calls: [_ | _]}, dimensions),
    do: Map.put(dimensions, :llm_usage_attribution, @llm_usage_attribution)

  defp token_telemetry_dimensions(_result, dimensions), do: dimensions

  defp record_partial_llm_telemetry(partial, dims, actor, incoming, selected_agent_result)
       when is_map(partial) do
    configured_agent =
      case selected_agent_result do
        {:ok, selected} -> selected
        _ -> nil
      end

    record_llm_call_telemetry(partial, dims, actor, incoming, configured_agent)
  end

  defp record_partial_llm_telemetry(_partial, _dims, _actor, _incoming, _selected_agent_result),
    do: :ok

  defp telemetry_actor({:ok, actor}), do: actor
  defp telemetry_actor(_), do: nil

  defp llm_call_dimensions(base, call, actor, incoming, configured_provider) do
    {provider, model} = llm_provider_and_model(call[:model], configured_provider)

    base
    |> maybe_put_dimension(:llm_provider, provider)
    |> maybe_put_dimension(:model, model)
    |> put_actor_dimensions(actor)
    |> maybe_put_dimension(:conversation_id, metadata_value(incoming, :conversation_id))
    |> maybe_put_dimension(:session_id, metadata_value(incoming, :session_id))
  end

  defp llm_provider_and_model(model, configured_provider) when is_binary(model) do
    case String.split(model, ":", parts: 2) do
      [provider, model_name] when provider != "" and model_name != "" -> {provider, model_name}
      _ -> {configured_provider, model}
    end
  end

  defp llm_provider_and_model(_model, configured_provider), do: {configured_provider, nil}

  defp configured_provider(%Zaq.Agent.ConfiguredAgent{} = configured_agent) do
    case Agent.runtime_provider_for_agent(configured_agent) do
      {:ok, provider} -> to_string(provider)
      _ -> nil
    end
  end

  defp configured_provider(_), do: nil

  defp put_actor_dimensions(dimensions, actor) do
    case ExecutionActor.identity(actor) do
      {:ok, {:person, id}} ->
        dimensions
        |> Map.put(:actor_type, "person")
        |> Map.put(:actor_id, to_string(id))
        |> Map.put(:person_id, to_string(id))

      {:ok, {kind, subject}} ->
        dimensions
        |> Map.put(:actor_type, to_string(kind))
        |> Map.put(:actor_id, subject)

      _ ->
        dimensions
    end
  end

  defp metadata_value(%Incoming{metadata: metadata}, key) when is_map(metadata),
    do: Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

  defp metadata_value(_incoming, _key), do: nil

  defp maybe_put_dimension(dimensions, _key, nil), do: dimensions
  defp maybe_put_dimension(dimensions, _key, ""), do: dimensions
  defp maybe_put_dimension(dimensions, key, value), do: Map.put(dimensions, key, value)

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

  defp append_attachments(content, attachments, scope)
       when is_binary(content) and is_list(attachments) and attachments != [] do
    metadata =
      Enum.map(attachments, fn attachment ->
        case OpaqueAliases.alias_record_metadata(attachment, scope) do
          {:ok, metadata} -> metadata
          {:error, _reason} -> Record.metadata(attachment)
        end
      end)

    Enum.join([content, "Attachments:", Jason.encode!(metadata)], "\n")
  end

  defp append_attachments(content, _attachments, _scope), do: content

  defp status_mod(opts) do
    Keyword.get(opts, :status_module, Zaq.Agent.Status)
  end
end
