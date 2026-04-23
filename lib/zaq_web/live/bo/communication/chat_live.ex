defmodule ZaqWeb.Live.BO.Communication.ChatLive do
  @moduledoc """
  Back-office chat.

  Full-size chat interface with live status callbacks.

  Requests are sent through `Zaq.NodeRouter.dispatch/1` so execution is
  decided on the Agent node (`Pipeline` by default, or explicit selected
  configured agent when present in event assigns).
  """

  use ZaqWeb, :live_view
  on_mount {ZaqWeb.Live.BO.Communication.ServiceGate, [:agent, :ingestion]}

  alias Zaq.Agent.{CitationNormalizer, History}
  alias Zaq.Channels.{Router, WebBridge}
  alias Zaq.Engine.Messages.{Incoming, Outgoing}
  alias Zaq.Event
  alias Zaq.Ingestion.ContentSource
  alias Zaq.NodeRouter
  alias Zaq.RuntimeDeps
  alias ZaqWeb.Live.BO.PreviewHelpers

  import ZaqWeb.Helpers.DateFormat,
    only: [
      format_time: 1,
      format_date: 1,
      inject_date_separators: 1,
      inject_relative_date_separators: 1
    ]

  require Logger

  @welcome_body "Welcome to ZAQ Chat! Ask me anything about your knowledge base."

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    _available = socket.assigns.service_available
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: current_user.id, else: nil

    session_id = generate_id()
    Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:#{session_id}")

    conversations =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [
        [user_id: user_id, limit: 50]
      ])

    conversations = if is_list(conversations), do: conversations, else: []

    {:ok,
     socket
     |> assign(:page_title, "Chat")
     |> assign(:current_path, "/bo/chat")
     |> assign(:session_id, session_id)
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
     |> assign(:preview, nil)
     |> assign(:conversations, conversations)
     |> assign(:current_conversation_id, nil)
     |> assign(:available_agents, list_chat_agents())
     |> assign(:selected_agent_id, "")
     |> assign(:active_filters, [])
     |> assign(:filter_suggestions, [])
     |> assign(:filter_query, "")
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
      active_filters = socket.assigns.active_filters

      user_msg = %{
        id: generate_id(),
        role: :user,
        body: trimmed,
        timestamp: DateTime.utc_now(),
        filters:
          Enum.map(active_filters, fn f ->
            %{label: f.label, source_prefix: f.source_prefix, type: f.type}
          end)
      }

      socket =
        socket
        |> update(:messages, &(&1 ++ [user_msg]))
        |> assign(:input_value, "")
        |> assign(:status, :thinking)
        |> assign(:status_message, "ZAQ is analyzing your question…")
        |> assign(:current_request_id, user_msg.id)
        |> assign(:active_filters, [])
        |> assign(:filter_suggestions, [])
        |> assign(:filter_query, "")

      session_id = socket.assigns.session_id
      request_id = user_msg.id

      Task.start(fn ->
        run_pipeline_async(
          session_id,
          request_id,
          trimmed,
          socket.assigns.history,
          socket.assigns.current_user,
          socket.assigns.selected_agent_id,
          active_filters
        )
      end)

      {:noreply, socket}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input_value, value)}
  end

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    {:noreply, assign(socket, :selected_agent_id, agent_id || "")}
  end

  def handle_event("load_conversation", %{"id" => id}, socket) do
    with conv when not is_nil(conv) <-
           NodeRouter.call(:engine, Zaq.Engine.Conversations, :get_conversation!, [id]),
         db_messages when is_list(db_messages) <-
           NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_messages, [conv]) do
      ui_messages = build_ui_messages_from_db(db_messages)
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

  def handle_event("use_suggestion", %{"prompt" => prompt}, socket) do
    {:noreply, assign(socket, :input_value, prompt)}
  end

  def handle_event("copy_message", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("open_preview_modal", %{"path" => path}, socket) do
    {:noreply, PreviewHelpers.open_preview(socket, path)}
  end

  def handle_event("close_preview_modal", _params, socket) do
    {:noreply, PreviewHelpers.close_preview(socket)}
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

  def handle_event("filter_autocomplete", %{"query" => query}, socket)
      when is_binary(query) and byte_size(query) > 0 do
    suggestions =
      node_router().call(:ingestion, Zaq.Ingestion, :list_document_sources, [query])

    suggestions = if is_list(suggestions), do: suggestions, else: []
    {:noreply, assign(socket, filter_suggestions: suggestions, filter_query: query)}
  end

  def handle_event("filter_autocomplete", _params, socket) do
    {:noreply, assign(socket, filter_suggestions: [], filter_query: "")}
  end

  def handle_event("add_content_filter", params, socket) do
    %{
      "source_prefix" => source_prefix,
      "connector" => connector,
      "label" => label,
      "type" => type_str
    } = params

    type = String.to_existing_atom(type_str)

    filter = %ContentSource{
      connector: connector,
      source_prefix: source_prefix,
      label: label,
      type: type
    }

    active_filters = socket.assigns.active_filters

    socket =
      if Enum.any?(active_filters, &(&1.source_prefix == source_prefix)) do
        socket
      else
        update(socket, :active_filters, &(&1 ++ [filter]))
      end

    {:noreply,
     socket
     |> assign(:filter_suggestions, [])
     |> assign(:filter_query, "")
     |> push_event("complete_filter_mention", %{label: label})}
  end

  def handle_event("remove_content_filter", %{"source_prefix" => source_prefix}, socket) do
    {:noreply,
     update(
       socket,
       :active_filters,
       &Enum.reject(&1, fn f -> f.source_prefix == source_prefix end)
     )}
  end

  def handle_event("clear_content_filters", _params, socket) do
    {:noreply, assign(socket, :active_filters, [])}
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
          do: %{
            user_id: current_user.id,
            rating: 1,
            comment: full_comment,
            feedback_reasons: reasons
          },
          else: %{
            channel_user_id: "bo_anonymous",
            rating: 1,
            comment: full_comment,
            feedback_reasons: reasons
          }

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

      raw_sources =
        Map.get(result, :sources) ||
          Map.get(result.metadata, :sources) ||
          Map.get(result.metadata, "sources") ||
          []

      %{body: normalized_body, sources: normalized_sources} =
        CitationNormalizer.normalize(trim_body(result.body), raw_sources)

      bot_msg = %{
        id: generate_id(),
        role: :bot,
        body: normalized_body,
        confidence: Map.get(result.metadata, :confidence_score),
        timestamp: DateTime.utc_now(),
        error: result.metadata[:error] || false,
        feedback: nil,
        sources: normalized_sources,
        live: true
      }

      {socket, bot_msg} =
        if result.metadata[:error] do
          {socket, bot_msg}
        else
          maybe_persist_conversation(
            socket,
            bot_msg,
            user_msg,
            result,
            current_user,
            normalized_body,
            normalized_sources
          )
        end

      updated_history =
        if result.metadata[:error] || Map.get(result.metadata, :confidence_score) == 0.0 do
          history
        else
          now = DateTime.utc_now()

          history
          |> Map.put(History.entry_key(now, :user), %{"body" => user_msg, "type" => "user"})
          |> Map.put(History.entry_key(now, :bot), %{"body" => normalized_body, "type" => "bot"})
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

  defp run_pipeline_async(
         session_id,
         request_id,
         user_msg,
         history,
         current_user,
         selected_agent_id,
         active_filters
       ) do
    source_filter = Enum.map(active_filters, & &1.source_prefix)

    incoming = %Incoming{
      content: user_msg,
      channel_id: "bo",
      author_id: current_user.id,
      provider: :web,
      content_filter: source_filter,
      metadata: %{session_id: session_id, request_id: request_id, user_content: user_msg}
    }

    # Explicit: BO-authenticated users with no person record get full access.
    # This is a deliberate policy decision, not a nil shortcut.
    bo_user_without_person = is_nil(Map.get(current_user, :person_id))

    event =
      Event.new(incoming, :agent,
        opts: [
          action: :run_pipeline,
          pipeline_opts: [
            history: history,
            skip_permissions: bo_user_without_person,
            telemetry_dimensions: %{channel_type: "bo", channel_config_id: "unknown"},
            on_status: WebBridge.on_status_callback(session_id, request_id),
            node_router: node_router()
          ]
        ]
      )
      |> maybe_put_agent_selection(selected_agent_id)

    outgoing = build_outgoing_from_event(node_router().dispatch(event), incoming)

    Router.deliver(outgoing)
  end

  defp maybe_put_agent_selection(%Event{} = event, selected_agent_id) do
    case selected_agent_id do
      id when id in [nil, ""] ->
        event

      id ->
        selection = %{"agent_id" => id, "source" => "bo_explicit"}
        %{event | assigns: Map.put(event.assigns || %{}, "agent_selection", selection)}
    end
  end

  defp build_outgoing_from_event(%Event{response: %Outgoing{} = outgoing}, _incoming),
    do: outgoing

  defp build_outgoing_from_event(%Event{response: {:error, reason}}, incoming) do
    Outgoing.from_pipeline_result(incoming, %{
      answer: "Sorry, something went wrong. Please try again.",
      confidence_score: nil,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: true,
      reason: inspect(reason),
      sources: []
    })
  end

  defp build_outgoing_from_event(_event, incoming) do
    Outgoing.from_pipeline_result(incoming, %{
      answer: "Sorry, something went wrong. Please try again.",
      confidence_score: nil,
      latency_ms: nil,
      prompt_tokens: nil,
      completion_tokens: nil,
      total_tokens: nil,
      error: true,
      sources: []
    })
  end

  defp node_router do
    RuntimeDeps.chat_live_node_router()
  end

  defp list_chat_agents do
    Zaq.Agent.list_active_agents()
    |> Enum.map(fn agent -> %{id: to_string(agent.id), name: agent.name} end)
  end

  defp persist_chat_conversation(
         user_msg,
         result,
         current_user,
         current_conversation_id,
         normalized_body,
         normalized_sources
       ) do
    user_id = if current_user, do: current_user.id, else: nil

    case resolve_conversation(current_user, current_conversation_id) do
      {:ok, conv} ->
        add_messages_to_conversation(
          conv,
          user_id,
          user_msg,
          result,
          normalized_body,
          normalized_sources
        )

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

  defp add_messages_to_conversation(
         conv,
         user_id,
         user_msg,
         result,
         normalized_body,
         normalized_sources
       ) do
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
          content: normalized_body,
          confidence_score: extract_confidence(Map.get(result.metadata, :confidence_score)),
          latency_ms: Map.get(result.metadata, :latency_ms),
          prompt_tokens: Map.get(result.metadata, :prompt_tokens),
          completion_tokens: Map.get(result.metadata, :completion_tokens),
          total_tokens: Map.get(result.metadata, :total_tokens),
          sources: normalized_sources
        }
      ])

    case bot_msg_result do
      {:ok, bot_msg} -> {:ok, conv.id, bot_msg.id}
      _ -> {:ok, conv.id, nil}
    end
  end

  defp maybe_persist_conversation(
         socket,
         bot_msg,
         user_msg,
         result,
         current_user,
         normalized_body,
         normalized_sources
       ) do
    case persist_chat_conversation(
           user_msg,
           result,
           current_user,
           socket.assigns.current_conversation_id,
           normalized_body,
           normalized_sources
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

    case node_router().call(:engine, Zaq.Engine.Conversations, :create_conversation, [attrs]) do
      {:ok, conv} = ok ->
        persist_welcome_message(conv)
        ok

      other ->
        other
    end
  end

  defp persist_welcome_message(conv) do
    node_router().call(:engine, Zaq.Engine.Conversations, :add_message, [
      conv,
      %{role: "assistant", content: @welcome_body, metadata: %{"welcome" => true}}
    ])
  end

  defp extract_confidence(%{score: score}), do: score
  defp extract_confidence(score) when is_float(score), do: score
  defp extract_confidence(score) when is_integer(score), do: score / 1
  defp extract_confidence(_), do: nil

  # ── Helpers ────────────────────────────────────────────────────────

  defp welcome_message(timestamp \\ nil) do
    %{
      id: generate_id(),
      role: :bot,
      body: @welcome_body,
      confidence: nil,
      timestamp: timestamp || DateTime.utc_now(),
      error: false,
      feedback: nil,
      welcome: true
    }
  end

  defp welcome_message_from_db(%{role: "assistant", inserted_at: ts} = msg) do
    %{
      id: generate_id(),
      db_id: msg.id,
      role: :bot,
      body: msg.content || @welcome_body,
      confidence: nil,
      timestamp: ts,
      error: false,
      feedback: nil,
      welcome: true
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

  defp build_ui_messages_from_db([first | rest] = db_messages) do
    if welcome_message?(first) do
      [welcome_message_from_db(first) | Enum.map(rest, &db_message_to_ui/1)]
    else
      [welcome_message() | Enum.map(db_messages, &db_message_to_ui/1)]
    end
  end

  defp build_ui_messages_from_db([]), do: [welcome_message()]

  defp welcome_message?(%{role: "assistant", metadata: %{"welcome" => true}}), do: true
  defp welcome_message?(%{role: "assistant", content: @welcome_body}), do: true
  defp welcome_message?(_), do: false

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
      body: trim_body(content),
      confidence: msg.confidence_score,
      timestamp: msg.inserted_at,
      error: false,
      feedback: infer_feedback_from_ratings(ratings),
      sources: normalize_sources(msg.sources || [])
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
          now = msg.inserted_at

          updated =
            history
            |> Map.put(History.entry_key(now, :user), %{"body" => last_user, "type" => "user"})
            |> Map.put(History.entry_key(now, :bot), %{
              "body" => trim_body(msg.content || ""),
              "type" => "bot"
            })

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

  defp trim_body(body) when is_binary(body) do
    String.trim(body)
  end

  defp trim_body(_), do: ""

  defp normalize_sources(sources) when is_list(sources) do
    sources
    |> Enum.with_index(1)
    |> Enum.map(fn {source, index} -> normalize_source_entry(source, index) end)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_sources(_), do: []

  defp normalize_source_entry(
         %{"type" => "document", "path" => path, "index" => src_index},
         _index
       )
       when is_binary(path) and path != "" and is_integer(src_index),
       do: %{"index" => src_index, "type" => "document", "path" => path}

  defp normalize_source_entry(
         %{"type" => "memory", "label" => label, "index" => src_index},
         _index
       )
       when is_binary(label) and label != "" and is_integer(src_index),
       do: %{"index" => src_index, "type" => "memory", "label" => label}

  defp normalize_source_entry(%{"type" => "document", "path" => path}, index)
       when is_binary(path) and path != "",
       do: %{"index" => index, "type" => "document", "path" => path}

  defp normalize_source_entry(%{"type" => "memory", "label" => label}, index)
       when is_binary(label) and label != "",
       do: %{"index" => index, "type" => "memory", "label" => label}

  defp normalize_source_entry(%{path: path}, index) when is_binary(path) and path != "",
    do: %{"index" => index, "type" => "document", "path" => path}

  defp normalize_source_entry(%{"path" => path}, index) when is_binary(path) and path != "",
    do: %{"index" => index, "type" => "document", "path" => path}

  defp normalize_source_entry(path, index) when is_binary(path) and path != "",
    do: %{"index" => index, "type" => "document", "path" => path}

  defp normalize_source_entry(_, _), do: nil
end
