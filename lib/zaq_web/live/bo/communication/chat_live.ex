defmodule ZaqWeb.Live.BO.Communication.ChatLive do
  @moduledoc """
  Back-office chat.

  Full-size chat interface that delegates to `Zaq.Agent.Pipeline.run/2`
  with live status callbacks. Agent and Ingestion calls are routed via
  Zaq.NodeRouter so they work whether services run locally or on a peer node.
  """

  use ZaqWeb, :live_view

  alias Zaq.Accounts.Permissions
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.ServiceUnavailable

  import ZaqWeb.Helpers.DateFormat, only: [format_time: 1]

  # Required roles for the chat
  @required_roles [:agent, :ingestion]

  require Logger

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    available = ServiceUnavailable.available?(@required_roles)
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: current_user.id, else: nil

    conversations =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [
        [user_id: user_id, limit: 50]
      ])

    conversations = if is_list(conversations), do: conversations, else: []

    {:ok,
     socket
     |> assign(:page_title, "Chat")
     |> assign(:current_path, "/bo/chat")
     |> assign(:service_available, available)
     |> assign(:required_roles, @required_roles)
     |> assign(:messages, [welcome_message()])
     |> assign(:input_value, "")
     |> assign(:status, :idle)
     |> assign(:status_message, "")
     |> assign(:history, %{})
     |> assign(:current_request_id, nil)
     |> assign(:show_feedback_modal, false)
     |> assign(:feedback_message_id, nil)
     |> assign(:feedback_reasons, [])
     |> assign(:feedback_comment, "")
     |> assign(:conversations, conversations)
     |> assign(:current_conversation_id, nil)
     |> assign(:suggested_questions, [
       "What is ZAQ and what does it do?",
       "Which integrations does ZAQ support?",
       "How is ZAQ deployed?",
       "Does ZAQ support Arabic?"
     ])}
  end

  # Guard — ignore all events when service is unavailable
  def handle_event(_event, _params, %{assigns: %{service_available: false}} = socket) do
    {:noreply, socket}
  end

  # ── Events ─────────────────────────────────────────────────────────

  @impl true
  def handle_event("send_message", %{"message" => msg}, socket) when msg != "" do
    trimmed = String.trim(msg)

    if trimmed == "" do
      {:noreply, socket}
    else
      user_msg = %{
        id: generate_id(),
        role: :user,
        body: trimmed,
        timestamp: DateTime.utc_now()
      }

      socket =
        socket
        |> update(:messages, &(&1 ++ [user_msg]))
        |> assign(:input_value, "")
        |> assign(:status, :thinking)
        |> assign(:status_message, "ZAQ is analyzing your question…")
        |> assign(:current_request_id, user_msg.id)

      pid = self()
      request_id = user_msg.id

      Task.start(fn ->
        run_pipeline_async(
          pid,
          request_id,
          trimmed,
          socket.assigns.history,
          socket.assigns.current_user
        )
      end)

      {:noreply, socket}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input_value, value)}
  end

  def handle_event("load_conversation", %{"id" => id}, socket) do
    with conv when not is_nil(conv) <-
           NodeRouter.call(:engine, Zaq.Engine.Conversations, :get_conversation!, [id]),
         db_messages when is_list(db_messages) <-
           NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_messages, [conv]) do
      ui_messages = [welcome_message()] ++ Enum.map(db_messages, &db_message_to_ui/1)
      history = build_history_from_db_messages(db_messages)

      subscribe_to_conversation(id)

      {:noreply,
       socket
       |> assign(:messages, ui_messages)
       |> assign(:history, history)
       |> assign(:current_conversation_id, id)
       |> assign(:status, :idle)
       |> assign(:status_message, "")}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("clear_chat", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages, [welcome_message()])
     |> assign(:history, %{})
     |> assign(:status, :idle)
     |> assign(:status_message, "")
     |> assign(:current_conversation_id, nil)
     |> reload_sidebar_conversations()}
  end

  def handle_event("use_suggestion", %{"question" => question}, socket) do
    {:noreply, assign(socket, :input_value, question)}
  end

  def handle_event("copy_message", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("feedback", %{"id" => id, "type" => "positive"}, socket) do
    current_user = socket.assigns[:current_user]
    msg = Enum.find(socket.assigns.messages, &(Map.get(&1, :id) == id))

    socket =
      socket
      |> update(:messages, fn msgs ->
        Enum.map(msgs, fn
          %{id: ^id} = m -> Map.put(m, :feedback, :positive)
          m -> m
        end)
      end)

    if msg && Map.get(msg, :db_id) do
      rater_attrs =
        if current_user,
          do: %{user_id: current_user.id, rating: 5},
          else: %{channel_user_id: "bo_anonymous", rating: 5}

      NodeRouter.call(
        :engine,
        Zaq.Engine.Conversations,
        :rate_message_by_id,
        [msg.db_id, rater_attrs]
      )
    end

    {:noreply, socket}
  end

  def handle_event("feedback", %{"id" => id, "type" => "negative"}, socket) do
    {:noreply,
     socket
     |> assign(:show_feedback_modal, true)
     |> assign(:feedback_message_id, id)
     |> assign(:feedback_reasons, [])
     |> assign(:feedback_comment, "")}
  end

  def handle_event("close_feedback_modal", _params, socket) do
    {:noreply, assign(socket, :show_feedback_modal, false)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_feedback_reason", %{"reason" => reason}, socket) do
    reasons = socket.assigns.feedback_reasons

    updated =
      if reason in reasons,
        do: List.delete(reasons, reason),
        else: reasons ++ [reason]

    {:noreply, assign(socket, :feedback_reasons, updated)}
  end

  def handle_event("update_feedback_comment", %{"comment" => comment}, socket) do
    {:noreply, assign(socket, :feedback_comment, comment)}
  end

  def handle_event("submit_feedback", _params, socket) do
    id = socket.assigns.feedback_message_id
    reasons = socket.assigns.feedback_reasons
    comment = socket.assigns.feedback_comment
    current_user = socket.assigns[:current_user]

    msg = Enum.find(socket.assigns.messages, &(Map.get(&1, :id) == id))

    Logger.info("Feedback for message #{id}: reasons=#{inspect(reasons)}, comment=#{comment}")

    socket =
      socket
      |> update(:messages, fn msgs ->
        Enum.map(msgs, fn
          %{id: ^id} = m -> Map.put(m, :feedback, :negative)
          m -> m
        end)
      end)
      |> assign(:show_feedback_modal, false)

    if msg && Map.get(msg, :db_id) do
      full_comment =
        [Enum.join(reasons, ", "), comment]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      rater_attrs =
        if current_user,
          do: %{user_id: current_user.id, rating: 1, comment: full_comment},
          else: %{channel_user_id: "bo_anonymous", rating: 1, comment: full_comment}

      NodeRouter.call(
        :engine,
        Zaq.Engine.Conversations,
        :rate_message_by_id,
        [msg.db_id, rater_attrs]
      )
    end

    {:noreply, socket}
  end

  # ── Async pipeline messages ──────────────────────────────────────────

  @impl true
  def handle_info({:status_update, request_id, status, message}, socket) do
    if request_id == socket.assigns.current_request_id do
      {:noreply,
       socket
       |> assign(:status, status)
       |> assign(:status_message, message)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:title_updated, conv_id, title}, socket) do
    conversations =
      Enum.map(socket.assigns.conversations, fn
        %{id: ^conv_id} = conv -> Map.put(conv, :title, title)
        conv -> conv
      end)

    {:noreply, assign(socket, :conversations, conversations)}
  end

  def handle_info({:pipeline_result, request_id, result, user_msg}, socket) do
    if request_id != socket.assigns.current_request_id do
      {:noreply, socket}
    else
      history = socket.assigns.history
      current_user = socket.assigns[:current_user]

      bot_msg = %{
        id: generate_id(),
        role: :bot,
        body: clean_body(result.answer),
        confidence: result.confidence,
        timestamp: DateTime.utc_now(),
        error: result[:error] || false,
        feedback: nil,
        sources: extract_sources(result.answer),
        live: true
      }

      {socket, bot_msg} =
        if result[:error] do
          {socket, bot_msg}
        else
          maybe_persist_conversation(socket, bot_msg, user_msg, result, current_user)
        end

      updated_history =
        if result[:error] || result.confidence == 0 do
          history
        else
          now = DateTime.utc_now() |> DateTime.to_iso8601()

          history
          |> Map.put("#{now}_user", %{"body" => user_msg, "type" => "user"})
          |> Map.put("#{now}_bot", %{"body" => result.answer, "type" => "bot"})
        end

      socket =
        socket
        |> update(:messages, &(&1 ++ [bot_msg]))
        |> assign(:status, :idle)
        |> assign(:status_message, "")
        |> assign(:history, updated_history)
        |> assign(:current_request_id, nil)

      {:noreply, socket}
    end
  end

  # ── Async pipeline runner (runs inside Task) ───────────────────────

  defp run_pipeline_async(pid, request_id, user_msg, history, current_user) do
    role_ids = Permissions.list_accessible_role_ids(current_user)

    result =
      Zaq.Agent.Pipeline.run(user_msg,
        history: history,
        role_ids: role_ids,
        on_status: fn stage, msg -> update_status(pid, request_id, stage, msg) end,
        node_router: node_router()
      )

    send(pid, {:pipeline_result, request_id, result, user_msg})
  end

  defp update_status(pid, request_id, status, message) do
    send(pid, {:status_update, request_id, status, message})
    :ok
  end

  defp node_router do
    Application.get_env(:zaq, :chat_live_node_router_module, NodeRouter)
  end

  defp persist_chat_conversation(user_msg, result, current_user, current_conversation_id) do
    user_id = if current_user, do: current_user.id, else: nil

    case resolve_conversation(current_user, current_conversation_id) do
      {:ok, conv} ->
        add_messages_to_conversation(conv, user_id, user_msg, result)

      err ->
        Logger.warning("ChatLive: failed to persist conversation: #{inspect(err)}")
        :error
    end
  end

  defp resolve_conversation(current_user, nil), do: create_fresh_conversation(current_user)

  defp resolve_conversation(current_user, conversation_id) do
    case node_router().call(
           :engine,
           Zaq.Engine.Conversations,
           :get_conversation,
           [conversation_id]
         ) do
      %{} = conv -> {:ok, conv}
      _ -> create_fresh_conversation(current_user)
    end
  end

  defp add_messages_to_conversation(conv, user_id, user_msg, result) do
    if user_id && is_nil(conv.user_id) do
      node_router().call(
        :engine,
        Zaq.Engine.Conversations,
        :update_conversation,
        [conv, %{user_id: user_id}]
      )
    end

    node_router().call(:engine, Zaq.Engine.Conversations, :add_message, [
      conv,
      %{role: "user", content: user_msg}
    ])

    bot_msg_result =
      node_router().call(:engine, Zaq.Engine.Conversations, :add_message, [
        conv,
        %{
          role: "assistant",
          content: clean_body(result.answer),
          confidence_score: extract_confidence(result.confidence),
          sources: result.answer |> extract_sources() |> Enum.map(&%{"path" => &1})
        }
      ])

    case bot_msg_result do
      {:ok, bot_msg} -> {:ok, conv.id, bot_msg.id}
      _ -> {:ok, conv.id, nil}
    end
  end

  defp maybe_persist_conversation(socket, bot_msg, user_msg, result, current_user) do
    case persist_chat_conversation(
           user_msg,
           result,
           current_user,
           socket.assigns.current_conversation_id
         ) do
      {:ok, conv_id, bot_db_id} ->
        subscribe_to_conversation(conv_id)

        updated_socket =
          socket
          |> assign(:current_conversation_id, conv_id)
          |> reload_sidebar_conversations()

        updated_msg = Map.put(bot_msg, :db_id, bot_db_id)
        {updated_socket, updated_msg}

      _ ->
        {socket, bot_msg}
    end
  end

  defp create_fresh_conversation(current_user) do
    channel_user_id =
      if current_user, do: "bo_user_#{current_user.id}", else: "bo_anonymous"

    user_id = if current_user, do: current_user.id, else: nil

    attrs =
      %{channel_user_id: channel_user_id, channel_type: "bo"}
      |> then(fn a -> if user_id, do: Map.put(a, :user_id, user_id), else: a end)

    node_router().call(:engine, Zaq.Engine.Conversations, :create_conversation, [attrs])
  end

  defp extract_confidence(%{score: score}), do: score
  defp extract_confidence(score) when is_float(score), do: score
  defp extract_confidence(score) when is_integer(score), do: score / 1
  defp extract_confidence(_), do: nil

  # ── Helpers ────────────────────────────────────────────────────────

  defp welcome_message do
    %{
      id: generate_id(),
      role: :bot,
      body: "Welcome to ZAQ Chat! Ask me anything about your knowledge base.",
      confidence: nil,
      timestamp: DateTime.utc_now(),
      error: false,
      feedback: nil
    }
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp subscribe_to_conversation(conv_id) do
    Phoenix.PubSub.subscribe(Zaq.PubSub, "conversation:#{conv_id}")
  end

  defp reload_sidebar_conversations(socket) do
    user_id = socket.assigns[:current_user] && socket.assigns.current_user.id

    conversations =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [
        [user_id: user_id, limit: 50]
      ])

    assign(socket, :conversations, if(is_list(conversations), do: conversations, else: []))
  end

  defp db_message_to_ui(%{role: "user", content: content, inserted_at: ts}) do
    %{id: generate_id(), role: :user, body: content || "", timestamp: ts}
  end

  defp db_message_to_ui(%{role: "assistant"} = msg) do
    content = msg.content || ""
    ratings = Map.get(msg, :ratings, [])

    %{
      id: generate_id(),
      db_id: msg.id,
      role: :bot,
      body: clean_body(content),
      confidence: msg.confidence_score || 0.0,
      timestamp: msg.inserted_at,
      error: false,
      feedback: infer_feedback_from_ratings(ratings),
      sources: if(msg.sources != [], do: msg.sources, else: extract_sources(content))
    }
  end

  defp db_message_to_ui(msg),
    do: %{
      id: generate_id(),
      role: :bot,
      body: inspect(msg),
      timestamp: DateTime.utc_now(),
      error: false,
      feedback: nil,
      confidence: nil,
      sources: []
    }

  defp build_history_from_db_messages(messages) do
    messages
    |> Enum.reduce({%{}, nil}, fn msg, {history, last_user} ->
      case msg.role do
        "user" ->
          {history, msg.content}

        "assistant" when not is_nil(last_user) ->
          now = msg.inserted_at |> DateTime.to_iso8601()

          updated =
            history
            |> Map.put("#{now}_user", %{"body" => last_user, "type" => "user"})
            |> Map.put("#{now}_bot", %{"body" => msg.content, "type" => "bot"})

          {updated, nil}

        _ ->
          {history, last_user}
      end
    end)
    |> elem(0)
  end

  defp infer_feedback_from_ratings([]), do: nil
  defp infer_feedback_from_ratings([%{rating: r} | _]) when r >= 4, do: :positive
  defp infer_feedback_from_ratings([%{rating: r} | _]) when r <= 2, do: :negative
  defp infer_feedback_from_ratings(_), do: nil

  defp extract_sources(body) do
    Regex.scan(~r/\[source:\s*([^\]]+)\]/, body)
    |> Enum.map(fn [_, source] -> String.trim(source) end)
    |> Enum.uniq()
  end

  defp clean_body(body) do
    Regex.replace(~r/\s*\[source:\s*[^\]]+\]/u, body, "")
    |> String.trim()
  end
end
