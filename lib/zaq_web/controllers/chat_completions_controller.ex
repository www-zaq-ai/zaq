defmodule ZaqWeb.ChatCompletionsController do
  @moduledoc """
  OpenAI-compatible `POST /v1/chat/completions` for the `:chat` channel.

  The wire contract (request validation, completion and chunk shapes,
  keepalive, citations, usage, caller tools, errors) is specified in
  `docs/services/chat-completions.md`; this module implements it.

  ## Pipeline routing

  Requests flow through `CommunicationBridge.route_incoming_message/4` and
  `NodeRouter.dispatch/1` like every other channel bridge, so traces, Person
  resolution (`Zaq.People.IdentityResolver`) and conversation persistence come
  from the shared pipeline. The transport is a synchronous HTTP request, so the
  controller subscribes to `Zaq.Channels.ChatBridge.topic/1` BEFORE routing and
  waits until `ChatBridge.send_reply/2` broadcasts the pipeline `%Outgoing{}`
  back as `{:chat_result, request_id, outgoing}`.

  Streaming is progressive: the executor's `StreamEvents` flushes the answer in
  progress as `:stream_delta` upserts, `ChatBridge.upsert_message/3` forwards
  them as `{:chat_stream_delta, request_id, cumulative}`, and the controller
  emits the suffix not yet sent. The final result reconciles the authoritative
  answer with what was already streamed.

  Requests that offer caller tools, or answer caller tool calls, run on
  `Zaq.Agent.ClientToolRun` (see its moduledoc for why the agent server cannot
  serve them).

  ## Security

  - The bearer token (`ZaqWeb.Plugs.ChatBearerAuth`) authenticates the calling
    *service*, never the end user, so every identity field of the body
    (`user`, `zaq_user.name`) is an unverified claim that may only ever key a
    Person the chat channel owns. `zaq_user` carries no email on purpose:
    `People.match_person/1` matches on email first, across platforms, so an
    email would let any token holder select an existing Person, inherit its
    teams and rename it. See `Zaq.People.Resolver.normalize/2`.
  - A conversation is read or appended only when its `channel_user_id` is
    `user` and its `channel_type` is `"chat"` (IDOR guard: history loads by
    `conversation_id`).
  - Retrieval runs with the chat Person's permissions (`skip_permissions` stays
    false); chunks the caller may not read are never cited.
  """

  use ZaqWeb, :controller

  alias Zaq.Channels.{ChatBridge, CommunicationBridge}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Conversations.Conversation
  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Ingestion.DocumentProcessor

  @max_messages 200
  @source_marker ~r/\s*\[\[\.?source:[^\]]+\]\]/u
  # OpenAI's own cap on `tools`.
  @max_tools 128
  @max_sources 8
  @max_iter_sentinel "Maximum iterations reached"
  @default_result_timeout_ms 120_000
  @default_keepalive_ms 10_000

  # ---------------------------------------------------------------------------
  # POST /v1/chat/completions
  # ---------------------------------------------------------------------------

  def completions(conn, params) do
    with {:ok, question} <- fetch_question(params),
         {:ok, user_id} <- fetch_required(params, "user", "user (owner id) is required"),
         {:ok, convo_id} <-
           fetch_required(params, "conversation_id", "conversation_id is required"),
         {:ok, tooling} <- parse_tooling(params),
         {:ok, _conv} <- ensure_owned_conversation(convo_id, user_id) do
      run(conn, Map.put(params, :tooling, tooling), question, convo_id, user_id)
    else
      {:error, status, message} -> json_error(conn, status, message)
    end
  end

  defp run(conn, params, question, convo_id, user_id) do
    topic = ChatBridge.topic(convo_id)
    # Subscribe before routing so the reply broadcast can't win the race, and
    # ALWAYS release it: Bandit serves successive keep-alive requests in the
    # same process, so a leaked subscription would keep delivering another
    # conversation's completions into this process's mailbox forever.
    :ok = Phoenix.PubSub.subscribe(Zaq.PubSub, topic)

    try do
      do_run(conn, params, question, convo_id, user_id)
    after
      Phoenix.PubSub.unsubscribe(Zaq.PubSub, topic)
    end
  end

  defp do_run(conn, params, question, convo_id, user_id) do
    request_id = Ecto.UUID.generate()

    incoming =
      ChatBridge.to_internal(%{
        content: question,
        conversation_id: convo_id,
        author_id: user_id,
        author_name: zaq_user_field(params, "name"),
        message_id: request_id,
        source_filter: parse_source_filter(params)
      })

    acc = %{
      conn: conn,
      id: "chatcmpl-" <> Integer.to_string(System.unique_integer([:positive])),
      created: created_ts(),
      model: fetch(params, "model") || "zaq-chat",
      stream?: stream?(params),
      include_usage?: include_usage?(params),
      usage: nil,
      # Progressive streaming state: SSE headers/role frame are sent lazily on
      # the first delta; `sent` tracks the bytes already on the wire so the
      # final answer only appends its remainder.
      sse_started?: false,
      role_sent?: false,
      # A write failed: the client is gone (CANCEL-1).
      closed?: false,
      # Bytes already on the wire for the CURRENT ReAct segment; reset when a
      # new segment restarts the accumulator (see push_stream/2).
      sent: ""
    }

    # Grounding (an optional OpenAI `system` message) frames THIS run only —
    # passed as the run question so it is injected into retrieval but never
    # persisted (the stored user turn stays the clean question).
    # Commit the stream up front: clients see headers at once and the keepalive
    # below has a wire to write to.
    acc = if acc.stream?, do: ensure_sse_role(acc), else: acc

    run_opts =
      [
        question: with_system(system_content(params), question),
        cancel_topic: ChatBridge.cancel_topic(request_id)
      ] ++ params.tooling

    case route(incoming, run_opts) do
      # Sync hop: the pipeline result came straight back.
      %Outgoing{} = outgoing -> respond(acc, outgoing)
      # Async hop: deltas + result arrive via ChatBridge broadcasts over PubSub.
      :ok -> await_result(acc, request_id)
      {:error, reason} -> respond_error(acc, reason)
    end
  end

  defp route(incoming, run_opts) do
    CommunicationBridge.route_incoming_message(
      incoming,
      # No BO channel-config surface for chat: without a global default agent,
      # pin the default answering executor (agentic run + tool citations)
      # instead of falling back to the legacy pipeline.
      [default_answering_executor: true] ++ run_opts,
      actor_from_incoming(incoming)
    )
  end

  defp actor_from_incoming(incoming) do
    %{id: incoming.author_id, name: incoming.author_name, provider: incoming.provider}
  end

  # Idle timeout: the clock restarts on every delta, so a generating run is
  # never cut off mid-answer — only a silent pipeline trips it. Keepalives do
  # not restart it.
  defp await_result(acc, request_id) do
    timeout = Zaq.Config.get(:zaq, :chat_result_timeout_ms, @default_result_timeout_ms)
    await_result(acc, request_id, now_ms() + timeout)
  end

  defp await_result(acc, request_id, deadline) do
    # `min/2` with :infinity (non-stream) always yields the remaining time.
    wait = min(max(deadline - now_ms(), 0), keepalive_ms(acc))

    receive do
      {:chat_stream_delta, ^request_id, cumulative} ->
        acc |> push_stream(cumulative) |> unless_closed(request_id, &await_result(&1, request_id))

      {:chat_result, ^request_id, %Outgoing{} = outgoing} ->
        respond(acc, outgoing)
    after
      wait ->
        if now_ms() >= deadline do
          # CANCEL-2: the request ends without the result; so does the run.
          ChatBridge.cancel_run(request_id)
          respond_error(acc, :timeout)
        else
          acc
          |> keepalive()
          |> unless_closed(request_id, &await_result(&1, request_id, deadline))
        end
    end
  end

  # CANCEL-1/CANCEL-2: the client is gone, so nothing more is written and the
  # run is cancelled instead of spending tokens on an answer nobody reads.
  defp unless_closed(%{closed?: true} = acc, request_id, _continue) do
    ChatBridge.cancel_run(request_id)
    acc.conn
  end

  defp unless_closed(acc, _request_id, continue), do: continue.(acc)

  defp keepalive_ms(%{stream?: true}),
    do: Zaq.Config.get(:zaq, :chat_keepalive_ms, @default_keepalive_ms)

  defp keepalive_ms(_acc), do: :infinity

  defp keepalive(acc), do: write(acc, ": keepalive\n\n")

  defp write(acc, payload) do
    case chunk_out(acc.conn, payload) do
      {:ok, conn} -> %{acc | conn: conn}
      {:error, _reason} -> %{acc | closed?: true}
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # ---------------------------------------------------------------------------
  # Progressive deltas — `cumulative` is the answer text so far for the current
  # LLM-call segment. Emit only the suffix not yet on the wire; use the same
  # cleanup as the terminal result, then hold back any partial source marker.
  # If the text stops extending what was sent (a later ReAct
  # segment restarted the accumulator), stop streaming and let the final
  # result reconcile.
  # ---------------------------------------------------------------------------

  defp push_stream(%{stream?: false} = acc, _cumulative), do: acc

  defp push_stream(acc, cumulative) when is_binary(cumulative) do
    emittable =
      cumulative |> clean_answer() |> safe_stream_prefix() |> ltrim_if_new(acc)

    cond do
      emittable == acc.sent ->
        acc

      String.starts_with?(emittable, acc.sent) ->
        delta =
          binary_part(emittable, byte_size(acc.sent), byte_size(emittable) - byte_size(acc.sent))

        acc
        |> ensure_sse_role()
        |> emit_acc(&chunk(&1, %{content: delta}, nil))
        |> Map.put(:sent, emittable)

      true ->
        restart_segment(acc, emittable)
    end
  end

  defp push_stream(acc, _cumulative), do: acc

  # The cumulative text stopped extending what we sent, which means a new ReAct
  # segment restarted the accumulator. Since the controller pins the answering
  # executor, multi-segment runs are the NORMAL case — giving up here would stop
  # streaming for the rest of the run and deliver the real answer as one blocking
  # chunk. Emit a break and keep going, tracking only the new segment.
  defp restart_segment(acc, emittable) do
    case String.trim_leading(emittable) do
      "" ->
        %{acc | sent: ""}

      segment ->
        acc
        |> ensure_sse_role()
        |> emit_acc(&chunk(&1, %{content: "\n\n" <> segment}, nil))
        |> Map.put(:sent, segment)
    end
  end

  defp ltrim_if_new(text, %{sent: ""}), do: String.trim_leading(text)
  defp ltrim_if_new(text, _acc), do: text

  # Hold back a trailing "[", "[[" or unterminated "[[source:…" so a marker
  # split across flushes never leaks onto the wire, and trailing whitespace so
  # the marker regex's leading `\s*` can never retro-eat bytes already sent.
  defp safe_stream_prefix(text) do
    text
    |> cut_partial_marker()
    |> String.trim_trailing("[")
    |> String.trim_trailing()
  end

  defp cut_partial_marker(text) do
    case :binary.matches(text, "[[") do
      [] ->
        text

      matches ->
        {start, _len} = List.last(matches)
        tail = binary_part(text, start, byte_size(text) - start)

        if String.contains?(tail, "]]") do
          text
        else
          binary_part(text, 0, start)
        end
    end
  end

  defp ensure_sse_role(acc) do
    acc =
      if acc.sse_started?, do: acc, else: %{acc | conn: start_sse(acc.conn), sse_started?: true}

    if acc.role_sent? do
      acc
    else
      emit_acc(%{acc | role_sent?: true}, &chunk(&1, %{role: "assistant"}, nil))
    end
  end

  defp emit_acc(acc, frame_fun), do: write(acc, "data: #{Jason.encode!(frame_fun.(acc))}\n\n")

  # ---------------------------------------------------------------------------
  # Response — one pipeline result folded onto the OpenAI wire.
  # ---------------------------------------------------------------------------

  defp respond(acc, %Outgoing{} = outgoing) do
    answer = clean_answer(outgoing.body)
    acc = %{acc | usage: usage(outgoing)}

    case client_tool_calls(outgoing) do
      [] ->
        case classify(outgoing.metadata, answer) do
          :ok -> deliver(acc, answer, sources_from_outgoing(outgoing))
          {:error, reason} -> respond_error(acc, reason)
        end

      calls ->
        deliver_tool_calls(acc, answer, calls, sources_from_outgoing(outgoing))
    end
  end

  # Tool calls the caller executes (see `Zaq.Agent.ClientToolRun`), in OpenAI's
  # `tool_calls` shape: `arguments` is a JSON string.
  defp client_tool_calls(%Outgoing{metadata: metadata}) do
    metadata
    |> metadata_get(:client_tool_calls)
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn {call, index} ->
      %{
        index: index,
        id: non_empty(call_field(call, :id)) || "call_" <> Ecto.UUID.generate(),
        type: "function",
        function: %{
          name: call_field(call, :name),
          arguments: Jason.encode!(call_field(call, :arguments) || %{})
        }
      }
    end)
  end

  defp call_field(call, key), do: Map.get(call, key) || Map.get(call, Atom.to_string(key))

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_value), do: nil

  defp deliver_tool_calls(%{stream?: true} = acc, answer, calls, sources) do
    acc = ensure_sse_role(acc)
    acc = if answer == "", do: acc, else: finish_answer(acc, answer)
    conn = emit(acc.conn, chunk(acc, %{tool_calls: calls}, nil))
    conn = if sources == [], do: conn, else: emit(conn, sources_frame(acc, sources))
    conn |> emit(chunk(acc, %{}, "tool_calls")) |> emit_usage(acc) |> sse_done()
  end

  defp deliver_tool_calls(%{stream?: false} = acc, answer, calls, sources) do
    message = %{
      role: "assistant",
      content: if(answer == "", do: nil, else: answer),
      tool_calls: Enum.map(calls, &Map.delete(&1, :index))
    }

    json(acc.conn, completion(acc, message, sources, "tool_calls"))
  end

  # The pipeline never raises — errors come back flagged on the result. The
  # "max iterations" sentinel is not a real answer: surface it as an error
  # rather than a fabricated acknowledgement.
  defp classify(metadata, answer) do
    cond do
      metadata_get(metadata, :error) == true -> {:error, :pipeline_error}
      String.contains?(answer, @max_iter_sentinel) -> {:error, :max_iterations_reached}
      String.trim(answer) == "" -> {:error, :empty_answer}
      true -> :ok
    end
  end

  defp deliver(%{stream?: true} = acc, answer, sources) do
    acc = acc |> ensure_sse_role() |> finish_answer(answer)

    # Sources BEFORE the terminal stop chunk: a spec-compliant client stops
    # consuming at `finish_reason`, so anything after it is dropped — and
    # citations are the whole point of the zaq_sources extension.
    conn = if sources == [], do: acc.conn, else: emit(acc.conn, sources_frame(acc, sources))
    conn |> emit(chunk(acc, %{}, "stop")) |> emit_usage(acc) |> sse_done()
  end

  defp deliver(%{stream?: false} = acc, answer, sources) do
    json(acc.conn, completion(acc, %{role: "assistant", content: answer}, sources, "stop"))
  end

  # OpenAI `stream_options.include_usage`: one last chunk with empty `choices`
  # carries the usage of the whole request.
  defp emit_usage(conn, %{include_usage?: true, usage: %{} = usage} = acc),
    do: emit(conn, %{chunk(acc, %{}, nil) | choices: []} |> Map.put(:usage, usage))

  defp emit_usage(conn, _acc), do: conn

  # Token counts the LLM provider reported for the model calls of this request,
  # summed by the run. nil when the provider reported none: never estimated.
  defp usage(%Outgoing{metadata: metadata}) do
    prompt = metadata_get(metadata, :prompt_tokens)
    completion = metadata_get(metadata, :completion_tokens)

    if is_integer(prompt) and is_integer(completion) do
      %{
        prompt_tokens: prompt,
        completion_tokens: completion,
        total_tokens: metadata_get(metadata, :total_tokens) || prompt + completion
      }
    end
  end

  # Reconcile the authoritative final answer with what streaming already sent.
  defp finish_answer(%{sent: ""} = acc, answer),
    do: emit_acc(acc, &chunk(&1, %{content: answer}, nil))

  defp finish_answer(%{sent: sent} = acc, answer) do
    base = if String.starts_with?(answer, sent), do: sent, else: String.trim_trailing(sent)

    if String.starts_with?(answer, base) do
      case binary_part(answer, byte_size(base), byte_size(answer) - byte_size(base)) do
        "" -> acc
        rest -> emit_acc(acc, &chunk(&1, %{content: rest}, nil))
      end
    else
      # The streamed segment diverged from the final answer (a late ReAct
      # restart): append the authoritative answer after a break rather than
      # leaving the client with a partial intermediate.
      emit_acc(acc, &chunk(&1, %{content: "\n\n" <> answer}, nil))
    end
  end

  defp respond_error(%{stream?: true} = acc, reason) do
    acc =
      if acc.sse_started?,
        do: acc,
        else: %{acc | conn: start_sse(acc.conn), sse_started?: true}

    # A failed run still reports the usage of the model calls it made (USAGE-4).
    acc.conn
    |> emit(stream_error(acc, reason))
    |> emit_usage(acc)
    |> sse_done()
  end

  defp respond_error(%{stream?: false} = acc, reason) do
    body = %{error: %{message: error_message(reason)}}

    acc.conn
    |> put_status(502)
    |> json(if acc.usage, do: Map.put(body, :usage, acc.usage), else: body)
  end

  # ---------------------------------------------------------------------------
  # Ownership gate (IDOR guard) + conversation lifecycle.
  # ---------------------------------------------------------------------------

  defp ensure_owned_conversation(convo_id, user_id) do
    # Validate the UUID up front so a malformed id is a clean 400 regardless of
    # which cast exception the Repo would raise (the rescue below stays as a
    # belt-and-suspenders guard).
    case Ecto.UUID.cast(convo_id) do
      {:ok, valid_id} -> gate_conversation(valid_id, user_id)
      :error -> {:error, 400, "invalid conversation_id"}
    end
  end

  defp gate_conversation(convo_id, user_id) do
    case Conversations.get_conversation(convo_id) do
      %Conversation{channel_user_id: ^user_id, channel_type: "chat"} = conv ->
        {:ok, conv}

      %Conversation{} ->
        {:error, 403, "conversation does not belong to user"}

      nil ->
        open_conversation(convo_id, user_id)
    end
  rescue
    Ecto.Query.CastError -> {:error, 400, "invalid conversation_id"}
  end

  defp open_conversation(convo_id, user_id) do
    case Conversations.create_chat_conversation(convo_id, user_id) do
      {:ok, %Conversation{} = conv} ->
        {:ok, conv}

      {:error, _changeset} ->
        # Lost a create race (or the id is now taken): re-fetch and re-gate.
        case Conversations.get_conversation(convo_id) do
          %Conversation{channel_user_id: ^user_id, channel_type: "chat"} = conv -> {:ok, conv}
          %Conversation{} -> {:error, 403, "conversation does not belong to user"}
          nil -> {:error, 409, "could not open conversation"}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Citations — unique (document, page) rows from the run's retrieval tool
  # calls (carried on `outgoing.metadata[:tool_calls]`, json_safe-encoded),
  # capped at @max_sources.
  # ---------------------------------------------------------------------------

  defp sources_from_outgoing(%Outgoing{metadata: metadata}) do
    metadata
    |> metadata_get(:tool_calls)
    |> List.wrap()
    |> Enum.flat_map(&tool_call_chunks/1)
    |> Enum.reduce({MapSet.new(), []}, &maybe_add_source(&2, source_from_chunk(&1)))
    |> elem(1)
  end

  # `tool_call["response"]` is the json_safe-encoded raw tool result: either a
  # map (`%{"chunks" => [...]}`) or an encoded ok-tuple (`["ok", %{...}, ...]`).
  defp tool_call_chunks(tool_call) when is_map(tool_call) do
    tool_call |> metadata_get(:response) |> chunks_from_response()
  end

  defp tool_call_chunks(_tool_call), do: []

  # Chunks the caller may not read come back as an access-denied placeholder
  # that still names its document: they are never cited.
  defp chunks_from_response(%{} = response) do
    case metadata_get(response, :chunks) do
      chunks when is_list(chunks) -> Enum.filter(chunks, &readable_chunk?/1)
      _ -> []
    end
  end

  defp chunks_from_response(["ok" | rest]) do
    case Enum.find(rest, &is_map/1) do
      nil -> []
      inner -> chunks_from_response(inner)
    end
  end

  defp chunks_from_response(_response), do: []

  defp readable_chunk?(%{} = chunk),
    do: metadata_get(chunk, :content) != DocumentProcessor.access_denied_message()

  defp readable_chunk?(_chunk), do: false

  defp maybe_add_source(acc, nil), do: acc

  defp maybe_add_source({seen, sources} = acc, {key, did, src, page}) do
    if length(sources) >= @max_sources or MapSet.member?(seen, key) do
      acc
    else
      {MapSet.put(seen, key), sources ++ [%{document_id: did, source: src, page: page}]}
    end
  end

  defp source_from_chunk(chunk) do
    source = Map.get(chunk, "source") || Map.get(chunk, :source)
    document_id = Map.get(chunk, "document_id") || Map.get(chunk, :document_id)
    page = start_page(Map.get(chunk, "metadata") || Map.get(chunk, :metadata))

    if is_binary(source) and not is_nil(document_id),
      do: {{document_id, page}, document_id, source, page},
      else: nil
  end

  # Chunks of paged documents carry `"P<page>|L<line>"` locators (see
  # `Zaq.Ingestion.DocumentProcessor.build_metadata/1`); a chunk without one is
  # cited without a page.
  defp start_page(%{} = metadata) do
    with "P" <> rest <- Map.get(metadata, "start") || Map.get(metadata, :start),
         {page, "|" <> _line} <- Integer.parse(rest) do
      page
    else
      _ -> nil
    end
  end

  defp start_page(_metadata), do: nil

  defp sources_frame(acc, sources) do
    acc
    |> chunk(%{}, nil)
    |> Map.put(:zaq_sources, sources_payload(sources))
  end

  defp sources_payload(sources) do
    Enum.map(sources, fn %{document_id: did, source: src, page: page} ->
      %{sourceId: did, title: src, page: page}
    end)
  end

  # ---------------------------------------------------------------------------
  # OpenAI wire shapes.
  # ---------------------------------------------------------------------------

  defp chunk(acc, delta, finish_reason) do
    %{
      id: acc.id,
      object: "chat.completion.chunk",
      created: acc.created,
      model: acc.model,
      choices: [%{index: 0, delta: delta, finish_reason: finish_reason}]
    }
  end

  defp completion(acc, message, sources, finish_reason) do
    %{
      id: acc.id,
      object: "chat.completion",
      created: acc.created,
      model: acc.model,
      choices: [
        %{
          index: 0,
          message: message,
          finish_reason: finish_reason
        }
      ],
      zaq_sources: sources_payload(sources)
    }
    |> then(&if(acc.usage, do: Map.put(&1, :usage, acc.usage), else: &1))
  end

  # The SSE headers are already on the wire by the time most errors surface, so
  # the status is committed at 200 and the error has to travel in-band. A frame
  # carrying ONLY `error` is skipped by any client that pattern-matches on
  # `choices` — the user gets an empty bubble and nothing is surfaced anywhere.
  # Carry the message as content too, so a stock OpenAI client renders it.
  defp stream_error(acc, reason) do
    message = error_message(reason)

    %{
      id: acc.id,
      object: "chat.completion.chunk",
      created: acc.created,
      model: acc.model,
      choices: [%{index: 0, delta: %{content: message}, finish_reason: "stop"}],
      error: %{message: message, type: "server_error"}
    }
  end

  defp created_ts, do: System.system_time(:second)

  # Inline `[[source:…]]` / `[[.source:…]]` markers duplicate the structured
  # `zaq_sources` frame, so they never reach the wire.
  defp clean_answer(text) when is_binary(text) do
    text
    |> String.replace(@source_marker, "")
    |> String.replace(~r/[ \t]+\n/u, "\n")
    |> String.trim()
  end

  defp clean_answer(nil), do: ""
  defp clean_answer(other), do: other |> to_string() |> clean_answer()

  # ---------------------------------------------------------------------------
  # Request parsing.
  # ---------------------------------------------------------------------------

  defp fetch_question(params) do
    messages = fetch(params, "messages") || []

    cond do
      not is_list(messages) ->
        {:error, 400, "messages must be an array"}

      length(messages) > @max_messages ->
        {:error, 413, "too many messages (max #{@max_messages})"}

      true ->
        case last_user_content(messages) do
          text when is_binary(text) and text != "" -> {:ok, text}
          _ -> {:error, 400, "no user message provided"}
        end
    end
  end

  defp fetch_required(params, key, message) do
    case fetch(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, 400, message}
    end
  end

  # First `system`-role message → per-run framing (OpenAI-standard). Prepended to
  # the run question (see `run/5`), never persisted.
  defp system_content(params) do
    (fetch(params, "messages") || [])
    |> Enum.find_value(fn msg ->
      if fetch(msg, "role") == "system", do: message_text(fetch(msg, "content")), else: nil
    end)
  end

  defp with_system(system, question)
       when is_binary(system) and system != "" and is_binary(question),
       do: system <> "\n\n" <> question

  defp with_system(_system, question), do: question

  # Optional `source_filter` (a ZAQ extension): a list of source prefixes the
  # retrieval is restricted to. Accepts a list or single string; empty/absent →
  # nil (unrestricted). Enforces the councils per-commune isolation invariant.
  defp parse_source_filter(params) do
    case fetch(params, "source_filter") do
      list when is_list(list) ->
        case Enum.filter(list, &is_binary/1) do
          [] -> nil
          filtered -> filtered
        end

      value when is_binary(value) and value != "" ->
        [value]

      _ ->
        nil
    end
  end

  # Optional `zaq_user` (a ZAQ extension): `%{"name" => ...}` for the caller
  # identified by the standard `user` id. Chat Completions has no field for a
  # display name and this channel exposes no profile API for ZAQ to fetch one
  # from, so the caller supplies it here — it is what lets `Zaq.People` name the
  # Person instead of filing it under the raw user id. Any other key (notably
  # `email`) is ignored on purpose; see the Security section of the moduledoc.
  defp zaq_user_field(params, key) do
    case fetch(params, "zaq_user") do
      %{} = zaq_user ->
        case fetch(zaq_user, key) do
          value when is_binary(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # ---------------------------------------------------------------------------
  # Client tools (OpenAI `tools` / `tool_choice` / role "tool" messages).
  #
  # A request runs on `Zaq.Agent.ClientToolRun` when it offers the model tools
  # (and `tool_choice` is not "none") or continues a tool call, i.e. its
  # messages after the last user message carry the assistant `tool_calls` and
  # the matching `tool` results. Otherwise no run option is added and the
  # request takes the regular agent path.
  # ---------------------------------------------------------------------------

  defp parse_tooling(params) do
    with {:ok, tools} <- parse_tools(fetch(params, "tools")),
         {:ok, choice} <- parse_tool_choice(fetch(params, "tool_choice"), tools),
         {:ok, exchange} <- parse_tool_exchange(fetch(params, "messages")) do
      tools = if choice == "none", do: [], else: tools

      if tools == [] and exchange == [],
        do: {:ok, []},
        else: {:ok, [client_tools: tools, tool_choice: choice, tool_exchange: exchange]}
    end
  end

  defp parse_tools(nil), do: {:ok, []}

  defp parse_tools(tools) when is_list(tools) and length(tools) <= @max_tools do
    parsed = Enum.map(tools, &parse_tool/1)
    names = Enum.map(parsed, &(&1 && &1.name))

    cond do
      nil in parsed ->
        {:error, 400, ~s(each tool must be {"type": "function", "function": {"name": ...}})}

      Enum.uniq(names) != names ->
        {:error, 400, "tool names must be unique"}

      true ->
        {:ok, parsed}
    end
  end

  defp parse_tools(tools) when is_list(tools),
    do: {:error, 400, "too many tools (max #{@max_tools})"}

  defp parse_tools(_tools), do: {:error, 400, "tools must be an array"}

  defp parse_tool(%{"type" => "function", "function" => %{"name" => name} = function})
       when is_binary(name) and name != "" do
    %{
      name: name,
      description: string_or(fetch(function, "description"), ""),
      parameters:
        map_or(fetch(function, "parameters"), %{"type" => "object", "properties" => %{}})
    }
  end

  defp parse_tool(_tool), do: nil

  defp parse_tool_choice(choice, _tools) when choice in [nil, "auto", "none", "required"],
    do: {:ok, choice}

  defp parse_tool_choice(%{"type" => "function", "function" => %{"name" => name}} = choice, tools) do
    if Enum.any?(tools, &(&1.name == name)),
      do: {:ok, choice},
      else: {:error, 400, "tool_choice names a function that is not in tools"}
  end

  defp parse_tool_choice(_choice, _tools), do: {:error, 400, "invalid tool_choice"}

  # The assistant tool_calls and tool results that followed the last user
  # message: ZAQ never stored them, so the caller's copy is the source of truth.
  defp parse_tool_exchange(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.take_while(&(fetch(&1, "role") != "user"))
    |> Enum.reverse()
    |> Enum.filter(&(fetch(&1, "role") in ["assistant", "tool"]))
    |> Enum.reduce_while({:ok, [], %{}}, &exchange_message/2)
    |> case do
      {:ok, exchange, pending} when map_size(pending) == 0 ->
        {:ok, Enum.reverse(exchange)}

      {:ok, _exchange, _pending} ->
        {:error, 400, "every tool_call needs a tool message answering it"}

      {:error, message} ->
        {:error, 400, message}
    end
  end

  defp parse_tool_exchange(_messages), do: {:ok, []}

  defp exchange_message(%{"role" => "assistant"} = msg, {:ok, acc, pending}) do
    case parse_tool_calls(fetch(msg, "tool_calls")) do
      {:ok, []} ->
        {:cont, {:ok, acc, pending}}

      {:ok, calls} ->
        entry = %{
          role: :assistant,
          content: message_text(fetch(msg, "content")),
          tool_calls: calls
        }

        {:cont, {:ok, [entry | acc], Map.merge(pending, Map.new(calls, &{&1.id, &1.name}))}}

      {:error, message} ->
        {:halt, {:error, message}}
    end
  end

  defp exchange_message(%{"role" => "tool"} = msg, {:ok, acc, pending}) do
    id = fetch(msg, "tool_call_id")

    case Map.pop(pending, id) do
      {nil, _pending} ->
        {:halt, {:error, "tool message references an unknown tool_call_id"}}

      {name, pending} ->
        entry = %{
          role: :tool,
          tool_call_id: id,
          name: name,
          content: message_text(fetch(msg, "content")) || ""
        }

        {:cont, {:ok, [entry | acc], pending}}
    end
  end

  defp parse_tool_calls(nil), do: {:ok, []}

  defp parse_tool_calls(calls) when is_list(calls) do
    Enum.reduce_while(calls, {:ok, []}, fn
      %{"id" => id, "function" => %{"name" => name} = function}, {:ok, acc}
      when is_binary(id) and id != "" and is_binary(name) ->
        case decode_arguments(fetch(function, "arguments")) do
          {:ok, arguments} -> {:cont, {:ok, acc ++ [%{id: id, name: name, arguments: arguments}]}}
          :error -> {:halt, {:error, "tool_calls arguments must be a JSON object string"}}
        end

      _call, _acc ->
        {:halt, {:error, "each tool_call needs an id and function.name"}}
    end)
  end

  defp parse_tool_calls(_calls), do: {:error, "tool_calls must be an array"}

  defp decode_arguments(nil), do: {:ok, %{}}

  defp decode_arguments(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{} = arguments} -> {:ok, arguments}
      _ -> :error
    end
  end

  defp decode_arguments(_arguments), do: :error

  defp string_or(value, _default) when is_binary(value), do: value
  defp string_or(_value, default), do: default

  defp map_or(%{} = value, _default), do: value
  defp map_or(_value, default), do: default

  defp stream?(params), do: fetch(params, "stream") == true

  defp include_usage?(params),
    do: params |> fetch("stream_options") |> fetch("include_usage") == true

  defp last_user_content(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if fetch(msg, "role") == "user", do: message_text(fetch(msg, "content")), else: nil
    end)
  end

  defp message_text(text) when is_binary(text), do: text

  defp message_text(parts) when is_list(parts) do
    Enum.map_join(parts, "", fn part -> fetch(part, "text") || "" end)
  end

  defp message_text(_), do: nil

  # ---------------------------------------------------------------------------
  # SSE writer.
  # ---------------------------------------------------------------------------

  defp start_sse(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
  end

  defp emit(conn, event) when is_map(event) do
    case chunk_out(conn, "data: #{Jason.encode!(event)}\n\n") do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp sse_done(conn) do
    case chunk_out(conn, "data: [DONE]\n\n") do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp chunk_out(conn, payload), do: Plug.Conn.chunk(conn, payload)

  defp json_error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: %{message: message}})
  end

  defp error_message(:empty_answer), do: "No answer was generated."
  defp error_message(:max_iterations_reached), do: "The search did not reach an answer."
  defp error_message(:timeout), do: "The answer took too long. Please try again."
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(_reason), do: "Something went wrong. Please try again."

  defp metadata_get(map, key) when is_map(map) and is_atom(key),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp metadata_get(_map, _key), do: nil

  defp fetch(map, key) when is_map(map), do: Map.get(map, key)
  defp fetch(_map, _key), do: nil
end
