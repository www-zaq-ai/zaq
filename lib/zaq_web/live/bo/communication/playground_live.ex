defmodule ZaqWeb.Live.BO.Communication.PlaygroundLive do
  @moduledoc """
  Back-office chat playground.

  Full-size chat interface that connects to the RAG agent pipeline:

      User message
        → PromptGuard.validate/1
        → Retrieval.ask/2          (shows "searching …" indicator)
        → DocumentProcessor.query_extraction/1
        → PromptTemplate.render("answering", …)
        → Answering.ask/2
        → PromptGuard.output_safe?/1
        → push answer to UI

  Agent and Ingestion calls are routed via Zaq.NodeRouter so they
  work whether the services run locally or on a peer node.
  """

  use ZaqWeb, :live_view

  alias Zaq.Agent.{Answering, PromptGuard, Retrieval}
  alias Zaq.Agent.PromptTemplate
  alias Zaq.Ingestion.DocumentProcessor
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.ServiceUnavailable

  # Required roles for the playground
  @required_roles [:agent, :ingestion]

  require Logger

  @no_answer_signal "I don't have enough information to answer that question."

  # ── Lifecycle ──────────────────────────────────────────────────────

  @impl true
  def mount(_params, _session, socket) do
    available = ServiceUnavailable.available?(@required_roles)

    {:ok,
     socket
     |> assign(:page_title, "Playground")
     |> assign(:current_path, "/bo/playground")
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
      Task.start(fn -> run_pipeline_async(pid, request_id, trimmed, socket.assigns.history) end)

      {:noreply, socket}
    end
  end

  def handle_event("send_message", _params, socket), do: {:noreply, socket}

  def handle_event("update_input", %{"message" => value}, socket) do
    {:noreply, assign(socket, :input_value, value)}
  end

  def handle_event("clear_chat", _params, socket) do
    {:noreply,
     socket
     |> assign(:messages, [welcome_message()])
     |> assign(:history, %{})
     |> assign(:status, :idle)
     |> assign(:status_message, "")}
  end

  def handle_event("use_suggestion", %{"question" => question}, socket) do
    {:noreply, assign(socket, :input_value, question)}
  end

  def handle_event("copy_message", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("feedback", %{"id" => id, "type" => "positive"}, socket) do
    socket =
      socket
      |> update(:messages, fn msgs ->
        Enum.map(msgs, fn
          %{id: ^id} = msg -> Map.put(msg, :feedback, :positive)
          msg -> msg
        end)
      end)

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

    Logger.info("Feedback for message #{id}: reasons=#{inspect(reasons)}, comment=#{comment}")

    socket =
      socket
      |> update(:messages, fn msgs ->
        Enum.map(msgs, fn
          %{id: ^id} = msg -> Map.put(msg, :feedback, :negative)
          msg -> msg
        end)
      end)
      |> assign(:show_feedback_modal, false)

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

  def handle_info({:pipeline_result, request_id, result, user_msg}, socket) do
    if request_id != socket.assigns.current_request_id do
      {:noreply, socket}
    else
      history = socket.assigns.history

      bot_msg = %{
        id: generate_id(),
        role: :bot,
        body: clean_body(result.answer),
        confidence: result.confidence,
        timestamp: DateTime.utc_now(),
        error: result[:error] || false,
        feedback: nil,
        sources: extract_sources(result.answer)
      }

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

  defp run_pipeline_async(pid, request_id, user_msg, history) do
    result =
      with {:ok, clean_msg} <- PromptGuard.validate(user_msg),
           :ok <-
             update_status(pid, request_id, :retrieving, "ZAQ is searching your knowledge base…"),
           {:ok, retrieval_result} <- run_retrieval(clean_msg, history),
           :ok <-
             update_status(
               pid,
               request_id,
               :retrieving,
               retrieval_result.positive_answer
             ),
           {:ok, extraction_result} <- run_query_extraction(retrieval_result),
           :ok <- update_status(pid, request_id, :answering, "Formulating your answer…"),
           {:ok, answer_result} <-
             run_answering(clean_msg, extraction_result, retrieval_result, history),
           {:ok, safe_answer} <- PromptGuard.output_safe?(answer_result.answer) do
        confidence = Map.get(answer_result, :confidence, %{score: 1.0})

        if Answering.no_answer?(safe_answer) do
          %{answer: Answering.clean_answer(safe_answer), confidence: 0.0}
        else
          %{answer: safe_answer, confidence: confidence.score}
        end
      else
        {:error, :prompt_injection} ->
          %{answer: "I can only help with ZAQ-related questions.", confidence: 0, error: true}

        {:error, :role_play_attempt} ->
          %{answer: "I can only help with ZAQ-related questions.", confidence: 0, error: true}

        {:error, {:leaked, _phrase}} ->
          Logger.warning("PromptGuard: output leak detected, blocking response")
          %{answer: "I can only help with ZAQ-related questions.", confidence: 0, error: true}

        {:error, :no_results, negative_answer} ->
          %{answer: negative_answer, confidence: 0}

        {:error, :no_results} ->
          %{
            answer: "I couldn't find relevant information to answer your question.",
            confidence: 0
          }

        {:error, reason} ->
          Logger.error("Playground pipeline error: #{inspect(reason)}")
          %{answer: "Sorry, something went wrong. Please try again.", confidence: 0, error: true}
      end

    send(pid, {:pipeline_result, request_id, result, user_msg})
  end

  defp update_status(pid, request_id, status, message) do
    send(pid, {:status_update, request_id, status, message})
    :ok
  end

  # Routes Retrieval.ask to the node running Zaq.Agent.Supervisor,
  # then normalizes the response from string keys to atom keys locally.
  defp run_retrieval(clean_msg, history) do
    case node_router().call(:agent, Retrieval, :ask, [clean_msg, [history: history]]) do
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

  # Routes DocumentProcessor.query_extraction to the node running Zaq.Ingestion.Supervisor.
  defp run_query_extraction(%{query: query, negative_answer: negative_answer} = _retrieval) do
    case node_router().call(:ingestion, DocumentProcessor, :query_extraction, [query]) do
      {:ok, results} when results != [] -> {:ok, results}
      {:ok, []} -> {:error, :no_results, negative_answer}
      {:error, _} -> {:error, :no_results, negative_answer}
    end
  end

  # Routes Answering.ask to the node running Zaq.Agent.Supervisor.
  defp run_answering(question, query_results, retrieval, _history) do
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

    case node_router().call(:agent, Answering, :ask, [system_prompt]) do
      {:ok, %{answer: _, confidence: _} = result} -> {:ok, result}
      {:ok, answer} when is_binary(answer) -> {:ok, %{answer: answer, confidence: %{score: 1.0}}}
      error -> error
    end
  end

  defp node_router do
    Application.get_env(:zaq, :playground_live_node_router_module, NodeRouter)
  end

  # ── Helpers ────────────────────────────────────────────────────────

  defp welcome_message do
    %{
      id: generate_id(),
      role: :bot,
      body: "Welcome to ZAQ Playground! Ask me anything about your knowledge base.",
      confidence: nil,
      timestamp: DateTime.utc_now(),
      error: false,
      feedback: nil
    }
  end

  defp generate_id, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

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
