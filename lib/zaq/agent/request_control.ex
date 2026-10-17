defmodule Zaq.Agent.RequestControl do
  @moduledoc """
  Shared authorized request-control boundary for explicit Agent API controls and
  execution admission while a runtime is busy. Engine owns canonical admission,
  grants and durable receipts; this module owns authorized PID targeting and Jido
  control invocation. It never creates public answers or interprets provider data.
  Read-only recovery queries reuse the same Person-bound runtime targeting and
  report uncertainty until native execution and finalization have settled.
  """

  alias Zaq.Agent.{Answering, Factory, HistorySync, InputPrompt, ServerManager}
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Identity.ExecutionActor

  @type handoff :: {:followup, map()}

  @doc "Returns private request state only to the same currently authorized principal."
  def authorize(event, request_id) do
    with {:ok, state, identity} <- authorize_target(event, request_id),
         :ok <- authorize_person(event, state, identity),
         do: {:ok, state}
  end

  @doc "Reads private canonical input references and processing states for the current Person."
  def processing_status(%Event{request: request} = event)
      when is_map(request) and map_size(request) == 0 do
    factory = Keyword.get(event.opts, :factory_module, Factory)

    with true <- Keyword.get(event.opts, :confidential) == true,
         {:ok, {:person, id}} when id > 0 <- ExecutionActor.identity(event.actor),
         {:ok, candidates} <- ServerManager.runtime_candidates(event.actor) do
      states =
        candidates
        |> Enum.filter(&(is_binary(&1.execution_user_message_id) and not is_nil(&1.lease_token)))
        |> Enum.map(fn candidate ->
          %{
            user_message_id: candidate.execution_user_message_id,
            status: processing_candidate(candidate, factory)
          }
        end)

      {:ok, states}
    else
      _ -> {:error, :unauthorized}
    end
  catch
    :exit, _ -> {:error, :runtime_unavailable}
  end

  def processing_status(_event), do: {:error, :unauthorized}

  defp processing_candidate(%{lease_request_id: id, runtime_pid: pid}, factory)
       when is_binary(id) do
    case factory.request_state(pid, id) do
      {:ok, %{status: :pending}} -> :active
      # A completed native request may still be awaiting Engine finalization.
      _ -> :unknown
    end
  end

  defp processing_candidate(_candidate, _factory), do: :unknown

  defp authorize_target(event, request_id) do
    with {:ok, state} <- find_request(event.actor, nil, nil, request_id),
         {:ok, identity} <- ExecutionActor.identity(event.actor),
         {:ok, ^identity} <- ExecutionActor.identity(state[:actor]),
         :ok <- matching_scope(event.request, state) do
      {:ok, state, identity}
    else
      {:error, reason} when reason in [:not_found, :scope_conflict] -> {:error, reason}
      _ -> {:error, :unauthorized}
    end
  end

  @doc "Queues authorized canonical input before controlling the exact Jido incarnation."
  def control(event, request_id, content, action, binding, opts \\ [])
      when action in [:steer_request, :inject_request] do
    if is_reference(Keyword.get(event.opts, :history_session)) do
      do_control(event, request_id, content, action, binding, opts)
    else
      HistorySync.with_session(fn session ->
        event = %{event | opts: Keyword.put(event.opts, :history_session, session)}
        do_control(event, request_id, content, action, binding, opts)
      end)
    end
  end

  defp do_control(event, request_id, content, action, binding, opts) do
    factory = Keyword.get(event.opts, :factory_module, Factory)

    with {:ok, state} <- authorize_input(event, request_id, binding, content),
         :ok <-
           ServerManager.admitted_history_target(
             state[:runtime_pid],
             event.opts[:history_session]
           ),
         :ok <- ServerManager.current_request_target(state),
         {:ok, runtime} <- runtime(state) do
      followup? = opts[:followup?] == true

      case input_opts(event, state, content, request_id, binding, followup?) do
        {:ok, input_opts} ->
          payload =
            (input_opts[:input_presentation] || state[:input_presentation] || %{})
            |> Map.merge(%{content: content, attachments: Keyword.get(opts, :attachments, [])})
            |> InputPrompt.render_message(opaque_alias_scope: state.server_id)

          invoke_control(
            factory,
            runtime,
            payload,
            action,
            Keyword.delete(input_opts, :input_presentation)
          )
          |> retain_rejection(event, state, input_opts)
          |> followup_disposition(
            state,
            request_id,
            Keyword.get(input_opts, :extra_refs),
            followup?
          )
          |> include_answer_binding(input_opts, opts)

        {:error, {:closed_before_accept, receipt}} when followup? ->
          {:followup, followup_binding(state, request_id, receipt.refs)}

        error ->
          error
      end
    end
  end

  defp include_answer_binding({:ok, result}, input_opts, opts) do
    if opts[:include_answer_binding] do
      refs = Keyword.get(input_opts, :extra_refs, %{})
      {:ok, %{result: result, assistant_message_id: refs[:assistant_message_id]}}
    else
      {:ok, result}
    end
  end

  defp include_answer_binding(result, _input_opts, _opts), do: result

  defp authorize_input(event, request_id, nil, _content), do: authorize(event, request_id)

  defp authorize_input(event, request_id, binding, content) do
    with {:ok, state, _identity} <- authorize_target(event, request_id),
         {:ok, projection} <-
           HistorySync.execution_admission(event.opts, binding, event.actor, content),
         do: {:ok, Map.put(state, :input_presentation, projection[:input])}
  end

  defp invoke_control(factory, runtime, content, :steer_request, opts) do
    factory.steer(runtime, content, opts)
  catch
    :exit, _ -> {:error, :stale_runtime}
  end

  defp invoke_control(factory, runtime, content, :inject_request, opts) do
    factory.inject(runtime, content, opts)
  catch
    :exit, _ -> {:error, :stale_runtime}
  end

  defp retain_rejection({:error, reason} = result, event, state, opts) do
    case Keyword.get(opts, :extra_refs) do
      %{message_id: _} = refs -> persist_rejection(event, state, refs, reason, result)
      _ -> result
    end
  end

  defp retain_rejection(result, _event, _state, _opts), do: result

  defp persist_rejection(event, state, refs, reason, result) do
    router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

    request =
      Event.new(
        %{
          root_user_message_id: state.execution_user_message_id,
          root_execution_id: refs[:root_execution_id] || state[:execution_id],
          user_message_id: refs.message_id,
          execution_id: refs[:execution_id],
          reason: rejection_category(reason)
        },
        :engine,
        actor: event.actor,
        opts: [action: :reject_execution_input, confidential: true]
      )

    case router.dispatch(request) do
      %{response: :ok} -> result
      %{response: {:error, :input_consumed}} -> {:error, :input_consumed}
      %{response: {:error, failure}} -> {:error, {:input_receipt_failed, failure}}
      _ -> {:error, {:input_receipt_failed, :unavailable}}
    end
  end

  @doc "Routes a verified same-Person explicit incoming input before request status side effects."
  def queue_incoming(
        event,
        incoming,
        %{kind: :canonical, transcript_id: transcript_id},
        binding,
        agent_id
      ) do
    scope = "history:#{transcript_id}:person:#{ActorNormalizer.person_id(event.actor)}"
    agent_id = agent_id || Answering.answering_configured_agent().id

    case find_native_request(scope, event.actor, %{agent_id: agent_id}) do
      {:ok, {request_id, _state}} ->
        case control(event, request_id, incoming.content, :steer_request, binding,
               followup?: true,
               include_answer_binding: true,
               attachments: incoming.attachments
             ) do
          {:ok, accepted} ->
            {:queued,
             Outgoing.from_pipeline_result(incoming, %{
               answer: "",
               error: false,
               execution_disposition: "queued",
               assistant_message_id: accepted.assistant_message_id,
               root_request_id: request_id
             })}

          {:error, :server_retiring} ->
            :not_active

          {:error, _} = error ->
            error

          {:followup, disposition} ->
            {:followup, disposition}
        end

      {:error, :not_found} ->
        :not_active

      {:error, _} = error ->
        error
    end
  end

  def queue_incoming(_event, _incoming, _projection, _binding, _agent_id), do: :not_active

  @doc "Selects an exact native run from immutable bindings, not stream-derived phase labels."
  @spec find_native_request(String.t(), map(), term()) ::
          {:ok, {String.t(), map()}} | {:error, term()}
  def find_native_request(scope, actor, runtime \\ nil) do
    with {:ok, target} <- find_request(actor, scope, runtime, nil),
         do: {:ok, {target.request_id, target}}
  end

  defp find_request(actor, scope, runtime, request_id) do
    with {:ok, identity} <- ExecutionActor.identity(actor),
         {:ok, candidates} <- ServerManager.runtime_candidates(actor, scope, runtime) do
      candidates
      |> Enum.flat_map(&native_target(&1, identity, request_id))
      |> case do
        [target] -> {:ok, target}
        [] -> {:error, :not_found}
        _ -> {:error, :ambiguous_request}
      end
    else
      _ -> {:error, :not_found}
    end
  end

  defp native_target(candidate, identity, request_id) do
    with {:ok, target} <- Factory.request_target(candidate, request_id),
         {:ok, ^identity} <- ExecutionActor.identity(target.actor),
         true <- not is_nil(request_id) or target.accepting? do
      [target]
    else
      _ -> []
    end
  end

  defp runtime(%{runtime_pid: pid}) when is_pid(pid),
    do: if(Process.alive?(pid), do: {:ok, pid}, else: {:error, :stale_runtime})

  defp runtime(%{runtime_pid: _}), do: {:error, :stale_runtime}
  defp runtime(%{server_id: id}) when not is_nil(id), do: {:ok, id}
  defp runtime(_state), do: {:error, :missing_server_id}

  defp input_opts(
         _event,
         %{execution_user_message_id: id},
         _content,
         _request_id,
         nil,
         _followup?
       )
       when is_binary(id), do: {:error, :admission_required}

  defp input_opts(
         event,
         %{execution_user_message_id: id} = state,
         content,
         request_id,
         binding,
         followup?
       )
       when is_binary(id), do: queue_input(event, state, binding, content, request_id, followup?)

  defp input_opts(_event, _state, _content, request_id, _binding, _followup?),
    do: {:ok, [expected_request_id: request_id]}

  defp queue_input(event, state, binding, content, request_id, followup?) do
    router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

    request =
      Event.new(
        %{
          root_user_message_id: state.execution_user_message_id,
          binding: binding,
          content: content,
          root_execution_id: state[:execution_id],
          closed_disposition: followup?
        },
        :engine,
        actor: event.actor,
        opts: [action: :queue_execution_input, confidential: true]
      )

    case router.dispatch(request) do
      %{response: {:ok, receipt}} ->
        {:ok,
         [
           expected_request_id: request_id,
           extra_refs: receipt.refs,
           input_presentation: receipt[:input]
         ]}

      %{response: {:error, reason}} ->
        {:error, reason}

      _ ->
        {:error, :history_unavailable}
    end
  end

  defp matching_scope(request, state) do
    expected = state[:execution_scope]

    case Map.get(request, :execution_scope, Map.get(request, "execution_scope")) do
      nil -> :ok
      ^expected -> :ok
      _ -> {:error, :scope_conflict}
    end
  end

  defp authorize_person(event, state, {:person, _id}) do
    router = Keyword.get(event.opts, :node_router, Zaq.NodeRouter)

    request =
      Event.new(
        %{user_message_id: state[:execution_user_message_id], execution_id: state[:execution_id]},
        :engine,
        actor: event.actor,
        opts: [action: :authorize_execution_control, confidential: true]
      )

    case router.dispatch(request) do
      %{response: :ok} -> :ok
      _ -> {:error, :unauthorized}
    end
  end

  defp authorize_person(_event, _state, _identity), do: :ok

  defp rejection_category({:rejected, reason}) when reason in [:idle, :closed],
    do: :closed_before_accept

  defp rejection_category(reason), do: reason

  defp followup_disposition({:error, {:rejected, reason}}, state, id, refs, true)
       when reason in [:idle, :closed] and is_map(refs),
       do: {:followup, followup_binding(state, id, refs)}

  defp followup_disposition(result, _state, _id, _refs, _followup?), do: result

  defp followup_binding(state, id, refs) do
    %{
      root_request_id: id,
      root_user_message_id: state.execution_user_message_id,
      root_execution_id: refs.root_execution_id,
      receipt_execution_id: refs.execution_id,
      runtime_pid: state.runtime_pid,
      disposition: :closed_before_accept
    }
  end
end
