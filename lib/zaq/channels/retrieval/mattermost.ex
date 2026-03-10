defmodule Zaq.Channels.Retrieval.Mattermost do
  @moduledoc """
  Retrieval channel adapter for Mattermost.

  Connects to Mattermost via WebSocket, listens for incoming messages,
  and forwards user questions to the Engine pipeline.

  Implements `Zaq.Engine.RetrievalChannel`.

  Started dynamically by `Zaq.Engine.RetrievalSupervisor` when a Mattermost
  channel config with `kind: "retrieval"` is present and enabled in the database.

  ## Message filtering

  Only messages that meet ALL of these conditions are forwarded:
  1. The message is from a monitored retrieval channel (stored in DB)
  2. The message mentions `@zaq`
  3. The sender is not the bot itself

  Monitored channel IDs are loaded on connect and cached in state.
  Call `reload_channels/0` to refresh after BO config changes.

  ## RAG Pipeline

  When a valid question is received, the full pipeline runs asynchronously:

      User message
        → PromptGuard.validate/1
        → Retrieval.ask/2
        → DocumentProcessor.query_extraction/1
        → PromptTemplate.render("answering", …)
        → Answering.ask/1
        → PromptGuard.output_safe?/1
        → API.send_message/3 (reply in thread)
  """

  use Fresh

  require Logger

  alias Zaq.Agent.{Answering, PromptGuard, Retrieval}
  alias Zaq.Agent.PromptTemplate
  alias Zaq.Channels.PendingQuestions
  alias Zaq.Channels.Retrieval.Mattermost.API
  alias Zaq.Channels.Retrieval.Mattermost.EventParser
  alias Zaq.Channels.RetrievalChannel, as: RetChannel
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  @behaviour Zaq.Engine.RetrievalChannel

  @bot_mention ~r/@zaq\b/i
  @no_answer_signal "I don't have enough information to answer that question."

  # --- RetrievalChannel behaviour ---

  @impl Zaq.Engine.RetrievalChannel
  def connect(%Zaq.Channels.ChannelConfig{} = config) do
    uri = build_ws_uri(config)
    monitored = RetChannel.active_channel_ids("mattermost")

    state = %{
      token: config.token,
      config: config,
      monitored_channel_ids: MapSet.new(monitored)
    }

    opts = [
      headers: [{"authorization", "Bearer #{config.token}"}],
      name: {:local, __MODULE__}
    ]

    start_link(uri: uri, state: state, opts: opts)
  end

  @impl Zaq.Engine.RetrievalChannel
  def disconnect(pid) do
    Fresh.close(pid, 1000, "Normal Closure")
  end

  @impl Zaq.Engine.RetrievalChannel
  def send_message(channel_id, message, thread_id) do
    API.send_message(channel_id, message, thread_id)
  end

  @impl Zaq.Engine.RetrievalChannel
  def handle_event(event) do
    Logger.info("[Mattermost] Received event: #{inspect(event)}")
    :ok
  end

  @impl Zaq.Engine.RetrievalChannel
  def forward_to_engine(question) do
    channel_id = question.channel_id
    post_id = question.metadata.post_id
    thread_id = question.thread_id || post_id
    text = question.text

    Logger.info("[Mattermost] Processing question from #{question.metadata.sender_name}: #{text}")

    Task.start(fn ->
      run_pipeline(text, channel_id, thread_id)
    end)

    :ok
  end

  # --- Public API ---

  @doc """
  Reloads monitored channel IDs from the database.
  Call this after adding/removing retrieval channels in the BO.
  """
  def reload_channels do
    GenServer.cast(__MODULE__, :reload_channels)
  end

  # --- Fresh callbacks ---

  @impl Fresh
  def handle_connect(_status, _headers, state) do
    Logger.info(
      "[Mattermost] Connected to WebSocket — monitoring #{MapSet.size(state.monitored_channel_ids)} channel(s)"
    )

    {:ok, state}
  end

  @impl Fresh
  def handle_in({:text, raw}, state) do
    case Jason.decode(raw) do
      {:ok, %{"event" => event_type} = event} ->
        handle_mm_event(event_type, event, state)

      {:ok, other} ->
        Logger.debug("[Mattermost] Unhandled WS message: #{inspect(other)}")
        {:ok, state}

      {:error, reason} ->
        Logger.warning("[Mattermost] Failed to decode WS message: #{inspect(reason)}")
        {:ok, state}
    end
  end

  @impl Fresh
  def handle_disconnect(_code, _reason, _state) do
    Logger.warning("[Mattermost] Disconnected, reconnecting...")
    :reconnect
  end

  @impl Fresh
  def handle_info(:reload_channels, state) do
    monitored = RetChannel.active_channel_ids("mattermost")
    new_state = %{state | monitored_channel_ids: MapSet.new(monitored)}

    Logger.info(
      "[Mattermost] Reloaded monitored channels — now monitoring #{MapSet.size(new_state.monitored_channel_ids)} channel(s)"
    )

    {:ok, new_state}
  end

  def handle_info(_msg, state), do: {:ok, state}

  # --- Private: WebSocket event handling ---

  defp handle_mm_event("posted", event, state) do
    case EventParser.parse("posted", event) do
      {:ok, %{sender_name: "@zaq"}} ->
        {:ok, state}

      {:ok, post} ->
        cond do
          not monitored?(post.channel_id, state) ->
            Logger.debug(
              "[Mattermost] Ignoring message from unmonitored channel: #{post.channel_id}"
            )

            {:ok, state}

          pending_reply?(post) ->
            handle_pending_reply(post, state)

          not mentions_zaq?(post.message) ->
            Logger.debug("[Mattermost] Ignoring message without @zaq mention")
            {:ok, state}

          true ->
            text = strip_mention(post.message)

            forward_to_engine(%{
              text: text,
              channel_id: post.channel_id,
              user_id: post.user_id,
              thread_id: post.root_id,
              metadata: %{
                sender_name: post.sender_name,
                channel_name: post.channel_name,
                channel_type: post.channel_type,
                post_id: post.id,
                create_at: post.create_at
              }
            })

            {:ok, state}
        end

      {:error, reason} ->
        Logger.warning("[Mattermost] Failed to parse posted event: #{inspect(reason)}")
        {:ok, state}

      {:unknown, event_type} ->
        Logger.debug("[Mattermost] Unknown event type: #{event_type}")
        {:ok, state}
    end
  end

  defp handle_mm_event(event_type, _event, state) do
    Logger.debug("[Mattermost] Event: #{event_type}")
    {:ok, state}
  end

  defp handle_pending_reply(post, state) do
    case PendingQuestions.check_reply(post) do
      {:answered, answer, callback} ->
        Logger.info("[Mattermost] Answer received: #{answer}")
        callback.(answer)
        {:ok, state}

      :ignore ->
        {:ok, state}
    end
  end

  # --- Private: RAG Pipeline ---

  defp run_pipeline(user_msg, channel_id, thread_id) do
    # Send typing indicator while processing
    API.send_typing(channel_id, thread_id)

    result =
      with {:ok, clean_msg} <- PromptGuard.validate(user_msg),
           {:ok, retrieval_result} <- run_retrieval(clean_msg),
           {:ok, extraction_result} <- run_query_extraction(retrieval_result),
           {:ok, answer_result} <- run_answering(clean_msg, extraction_result, retrieval_result),
           {:ok, safe_answer} <- PromptGuard.output_safe?(answer_result.answer) do
        if Answering.no_answer?(safe_answer) do
          %{answer: Answering.clean_answer(safe_answer), confidence: 0.0}
        else
          %{answer: safe_answer, confidence: Map.get(answer_result, :confidence, %{score: 1.0})}
        end
      else
        {:error, :prompt_injection} ->
          %{answer: "I can only help with ZAQ-related questions.", error: true}

        {:error, :role_play_attempt} ->
          %{answer: "I can only help with ZAQ-related questions.", error: true}

        {:error, {:leaked, _phrase}} ->
          Logger.warning("[Mattermost] PromptGuard: output leak detected, blocking response")
          %{answer: "I can only help with ZAQ-related questions.", error: true}

        {:error, :no_results, negative_answer} ->
          %{answer: negative_answer}

        {:error, :no_results} ->
          %{answer: "I couldn't find relevant information to answer your question."}

        {:error, reason} ->
          Logger.error("[Mattermost] Pipeline error: #{inspect(reason)}")
          %{answer: "Sorry, something went wrong. Please try again.", error: true}
      end

    # Send the answer as a thread reply
    reply = clean_body(result.answer)

    case API.send_message(channel_id, reply, thread_id) do
      {:ok, _} ->
        Logger.info("[Mattermost] Reply sent to channel=#{channel_id} thread=#{thread_id}")

      {:error, reason} ->
        Logger.error("[Mattermost] Failed to send reply: #{inspect(reason)}")
    end
  end

  defp run_retrieval(clean_msg) do
    case NodeRouter.call(:agent, Retrieval, :ask, [clean_msg, [history: %{}]]) do
      {:ok,
       %{
         "query" => query,
         "language" => language,
         "positive_answer" => positive_answer,
         "negative_answer" => negative_answer
       }}
      when query != "" ->
        {:ok,
         %{
           query: query,
           language: language,
           positive_answer: positive_answer,
           negative_answer: negative_answer
         }}

      {:ok, %{"negative_answer" => negative_answer}} ->
        {:error, :no_results, negative_answer}

      {:ok, %{"error" => _}} ->
        {:error, :blocked}

      {:ok, _} ->
        {:error, :no_results}

      error ->
        error
    end
  end

  defp run_query_extraction(%{query: query, negative_answer: negative_answer}) do
    case NodeRouter.call(:ingestion, DocumentProcessor, :query_extraction, [query]) do
      {:ok, results} when results != [] -> {:ok, results}
      {:ok, []} -> {:error, :no_results, negative_answer}
      {:error, _} -> {:error, :no_results, negative_answer}
    end
  end

  defp run_answering(question, query_results, retrieval) do
    language = Map.get(retrieval, :language, "en")

    retrieved_data =
      query_results
      |> Enum.map(fn %{"content" => content, "source" => source} ->
        %{"content" => content, "source" => source}
      end)

    system_prompt =
      PromptTemplate.render("answering", %{
        question: question,
        retrieved_data: Jason.encode!(retrieved_data),
        language: language,
        no_answer_signal: @no_answer_signal
      })

    case NodeRouter.call(:agent, Answering, :ask, [system_prompt]) do
      {:ok, %{answer: _, confidence: _} = result} -> {:ok, result}
      {:ok, answer} when is_binary(answer) -> {:ok, %{answer: answer, confidence: %{score: 1.0}}}
      error -> error
    end
  end

  # --- Private: Helpers ---

  defp monitored?(channel_id, %{monitored_channel_ids: ids}) do
    MapSet.member?(ids, channel_id)
  end

  defp mentions_zaq?(message), do: Regex.match?(@bot_mention, message)

  defp strip_mention(message) do
    message
    |> String.replace(@bot_mention, "")
    |> String.trim()
  end

  defp pending_reply?(post) do
    post.root_id != nil and post.root_id != ""
  end

  defp clean_body(body) do
    body
    # Strip [source: ...] markers
    |> then(&Regex.replace(~r/\s*\[source:\s*[^\]]+\]/u, &1, ""))
    # Strip anchor tags but keep their text content
    |> then(&Regex.replace(~r/<a[^>]*>([^<]*)<\/a>/u, &1, "\\1"))
    # Strip all remaining HTML tags
    |> then(&Regex.replace(~r/<[^>]+>/u, &1, ""))
    # Decode common HTML entities
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&nbsp;", " ")
    # Collapse multiple blank lines into one
    |> then(&Regex.replace(~r/\n{3,}/, &1, "\n\n"))
    |> String.trim()
  end

  defp build_ws_uri(%{url: url}) do
    url
    |> String.replace_leading("https://", "wss://")
    |> String.replace_leading("http://", "ws://")
    |> Kernel.<>("/api/v4/websocket")
  end
end
