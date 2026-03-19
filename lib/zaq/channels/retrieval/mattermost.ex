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

  alias Zaq.Accounts
  alias Zaq.Accounts.Permissions
  alias Zaq.Agent.{Answering, PromptGuard, Retrieval}
  alias Zaq.Agent.PromptTemplate
  alias Zaq.Channels.PendingQuestions
  alias Zaq.Channels.Retrieval.Mattermost.API
  alias Zaq.Channels.Retrieval.Mattermost.EventParser
  alias Zaq.Channels.RetrievalChannel, as: RetChannel
  alias Zaq.Engine.Conversations
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter

  @behaviour Zaq.Engine.RetrievalChannel

  @bot_mention ~r/@zaq\b/i

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
    api_module().send_message(channel_id, message, thread_id)
  end

  @impl Zaq.Engine.RetrievalChannel
  def send_question(channel_id, question) do
    case api_module().send_message(channel_id, question, nil) do
      {:ok, %{"id" => post_id}} -> {:ok, post_id}
      {:ok, body} -> {:error, {:unexpected_response, body}}
      error -> error
    end
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
    channel_user_id = Map.get(question, :user_id)
    channel_config_id = Map.get(question, :channel_config_id)

    sender_name = question.metadata.sender_name
    Logger.info("[Mattermost] Processing question from #{sender_name}: #{text}")

    Task.start(fn ->
      run_pipeline(text, channel_id, thread_id, channel_user_id, channel_config_id, sender_name)
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
        handle_valid_post(post, state)

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

  defp handle_valid_post(post, state) do
    cond do
      not monitored?(post.channel_id, state) ->
        Logger.debug("[Mattermost] Ignoring message from unmonitored channel: #{post.channel_id}")

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
          channel_config_id: state |> Map.get(:config) |> then(&if(&1, do: &1.id, else: nil)),
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

  defp run_pipeline(
         user_msg,
         channel_id,
         thread_id,
         channel_user_id,
         channel_config_id,
         sender_name
       ) do
    api_module().send_typing(channel_id, thread_id)

    role_ids = resolve_role_ids(sender_name)

    result =
      Zaq.Agent.Pipeline.run(user_msg,
        role_ids: role_ids,
        node_router: node_router_module(),
        retrieval: retrieval_module(),
        document_processor: document_processor_module(),
        answering: answering_module(),
        prompt_guard: prompt_guard_module(),
        prompt_template: prompt_template_module()
      )

    # Send the answer as a thread reply
    reply = clean_body(result.answer)

    case api_module().send_message(channel_id, reply, thread_id) do
      {:ok, _} ->
        Logger.info("[Mattermost] Reply sent to channel=#{channel_id} thread=#{thread_id}")

      {:error, reason} ->
        Logger.error("[Mattermost] Failed to send reply: #{inspect(reason)}")
    end

    # Persist conversation asynchronously after replying
    unless Map.get(result, :error) do
      Task.start(fn ->
        persist_conversation(user_msg, result, channel_user_id, channel_config_id)
      end)
    end
  end

  defp persist_conversation(user_msg, result, channel_user_id, channel_config_id) do
    case Conversations.get_or_create_conversation_for_channel(
           channel_user_id,
           "mattermost",
           channel_config_id
         ) do
      {:ok, conv} ->
        Conversations.add_message(conv, %{role: "user", content: user_msg})

        Conversations.add_message(conv, %{
          role: "assistant",
          content: result.answer,
          confidence_score: extract_confidence_score(result.confidence)
        })

      err ->
        Logger.warning("[Mattermost] Failed to persist conversation: #{inspect(err)}")
    end
  end

  defp extract_confidence_score(%{score: score}), do: score
  defp extract_confidence_score(score) when is_float(score), do: score
  defp extract_confidence_score(_), do: nil

  # --- Private: Helpers ---

  # Resolves accessible role IDs for a Mattermost sender.
  # Falls back to nil (unfiltered) when the sender cannot be matched to a ZAQ user.
  # NOTE: `sender_name` is the Mattermost display name and may not match ZAQ username.
  # Follow-up: consider adding a `mattermost_username` field to User or a per-channel
  # default role in config.
  defp resolve_role_ids(nil), do: nil

  defp resolve_role_ids(sender_name) do
    case accounts_module().get_user_by_username(sender_name) do
      nil -> nil
      user -> Permissions.list_accessible_role_ids(user)
    end
  end

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

  defp accounts_module, do: Application.get_env(:zaq, :mattermost_accounts_module, Accounts)

  defp api_module, do: Application.get_env(:zaq, :mattermost_api_module, API)

  defp node_router_module,
    do: Application.get_env(:zaq, :mattermost_node_router_module, NodeRouter)

  defp prompt_guard_module,
    do: Application.get_env(:zaq, :mattermost_prompt_guard_module, PromptGuard)

  defp retrieval_module, do: Application.get_env(:zaq, :mattermost_retrieval_module, Retrieval)

  defp document_processor_module do
    Application.get_env(:zaq, :mattermost_document_processor_module, DocumentProcessor)
  end

  defp answering_module, do: Application.get_env(:zaq, :mattermost_answering_module, Answering)

  defp prompt_template_module do
    Application.get_env(:zaq, :mattermost_prompt_template_module, PromptTemplate)
  end
end
