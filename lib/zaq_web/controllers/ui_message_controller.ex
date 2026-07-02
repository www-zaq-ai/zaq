defmodule ZaqWeb.UiMessageController do
  @moduledoc """
  ZAQ emits the **Vercel AI SDK `UIMessageChunk` stream directly**. A stock
  `DefaultChatTransport` consumes this route as-is.

      POST /chat/ui-messages   {messages:[{role,content}], threadId}
        -> data: {"type":"start","messageId":...}
        -> data: {"type":"text-start","id":...}
        -> data: {"type":"text-delta","id":...,"delta":...}   (one per token,
              raw — keeps the model's inline [[source:X]] markers so the client
              can render numbered inline citations)
        -> data: {"type":"text-end","id":...}
        -> data: {"type":"source-url","sourceId":...,"url":...,"title":...,"page":N}*
        -> data: {"type":"finish"}
        -> data: [DONE]

      GET  /chat/documents/:id  -> {id, source, content, content_type}

  Citations are computed deterministically: the question is retrieved against the
  KB and each matching document becomes a `source-url` (title = its source, page
  = the cited chunk's page, parsed from `<!-- page: N -->` markers in the
  document markdown). Inline rendering ([N] where the model wrote `[[source:X]]`)
  is the client's job — the wire carries raw text + the numbered source list.

  Bearer auth (`ZAQ_CHAT_TOKEN`, constant-time, fail-closed).
  """

  use ZaqWeb, :controller

  require Logger

  alias Zaq.Agent.AnsweringRun
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Ingestion.{Document, DocumentProcessor}
  alias Zaq.NodeRouter
  alias Zaq.Repo

  @max_messages 200

  # ---------------------------------------------------------------------------
  # POST /chat/ui-messages
  # ---------------------------------------------------------------------------

  def run(conn, params) do
    with :ok <- authorize(conn),
         messages when is_list(messages) <- fetch(params, "messages") || [],
         true <- length(messages) <= @max_messages do
      conn |> start_stream() |> stream_ui(params)
    else
      {:error, status, message} -> json_error(conn, status, message)
      false -> json_error(conn, 413, "too many messages (max #{@max_messages})")
      _ -> json_error(conn, 400, "messages must be an array")
    end
  end

  defp stream_ui(conn, params) do
    id = "msg-" <> Integer.to_string(System.unique_integer([:positive]))
    conn = emit!(conn, %{type: "start", messageId: id})

    # Optional retrieval scope: when the client sends `source_filter` (a list of
    # source prefixes), BOTH the agent's search_knowledge_base retrieval AND the
    # deterministic citation retrieval are restricted to those documents — no
    # leak outside the scope. Absent/empty → nil → unrestricted.
    source_filter = parse_source_filter(params)

    case build_incoming(params) do
      {:ok, incoming} ->
        # Deterministic citations: retrieve against the RAW user question (not
        # `incoming.content`, which may carry a caller `system` prefix that would
        # skew the retrieval query), page-tag each doc.
        docs = retrieve_sources(last_user_content(fetch(params, "messages") || []), source_filter)

        # Run the Jido answering agent (streaming ReAct). Retrieval is scoped to
        # the PV via source_filter. This is an anonymous transport over public
        # records, so it retrieves with skip_permissions (no per-user identity);
        # the caller restricts the exposed corpus via source_filter.
        # (Grounding/prompt lives in the caller.)
        case AnsweringRun.build_request(incoming, [],
               source_filter: source_filter,
               skip_permissions: true
             ) do
          {:ok, events} ->
            %{conn: conn, id: id, open?: false, docs: docs, error: nil}
            |> fold(events)
            |> finish_ui()

          {:error, reason} ->
            ui_error(conn, id, reason)
        end

      {:error, reason} ->
        ui_error(conn, id, reason)
    end
  end

  defp fold(acc, events) do
    Enum.reduce_while(events, acc, fn event, acc ->
      acc = capture_sources(acc, AnsweringRun.extract_chunks(event))

      case AnsweringRun.classify_event(event) do
        {:text_delta, delta} -> {:cont, text_delta(acc, delta)}
        {:tool_call, _call} -> {:cont, acc}
        {:done, _final} -> {:halt, acc}
        {:error, reason} -> {:halt, %{acc | error: reason}}
        :ignore -> {:cont, acc}
      end
    end)
  end

  # Stream one token verbatim (markers kept for client-side inline citations).
  defp text_delta(acc, delta) do
    conn = if acc.open?, do: acc.conn, else: emit!(acc.conn, %{type: "text-start", id: acc.id})
    %{acc | conn: emit!(conn, %{type: "text-delta", id: acc.id, delta: delta}), open?: true}
  end

  defp finish_ui(%{error: reason} = acc) when not is_nil(reason) do
    acc.conn
    |> emit!(%{type: "error", errorText: error_message(reason)})
    |> emit!(%{type: "finish"})
    |> done()
  end

  defp finish_ui(acc) do
    conn = if acc.open?, do: emit!(acc.conn, %{type: "text-end", id: acc.id}), else: acc.conn

    conn
    |> emit_sources(acc.docs)
    |> emit!(%{type: "finish"})
    |> done()
  end

  defp ui_error(conn, _id, reason) do
    Logger.warning("UiMessageController run failed: #{inspect(reason)}")

    conn
    |> emit!(%{type: "error", errorText: error_message(reason)})
    |> emit!(%{type: "finish"})
    |> done()
  end

  # ---------------------------------------------------------------------------
  # Citations — retrieved documents, page-tagged.
  # ---------------------------------------------------------------------------

  defp capture_sources(acc, chunks), do: %{acc | docs: merge_chunks(acc.docs, chunks)}

  defp retrieve_sources(question, _source_filter) when not is_binary(question), do: %{}

  defp retrieve_sources(question, source_filter) do
    # Same permission scope as the answering agent (skip_permissions: true on this
    # anonymous public-records transport) so citations match what the agent reads.
    opts =
      [skip_permissions: true, source_filter: source_filter]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    case NodeRouter.call(:ingestion, DocumentProcessor, :query_extraction, [
           question,
           opts
         ]) do
      {:ok, chunks} -> merge_chunks(%{}, chunks)
      _ -> %{}
    end
  rescue
    _ -> %{}
  end

  # Reads an optional `source_filter` from the request body: a list of source
  # prefixes the retrieval is restricted to. Accepts a list of strings or a
  # single string; absent/empty/other → nil (no scoping).
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

  # docs: document_id -> %{source, page}. First (top-ranked) chunk per document
  # wins the page.
  defp merge_chunks(docs, chunks) when is_list(chunks) do
    Enum.reduce(chunks, docs, fn ch, m ->
      src = Map.get(ch, :source) || Map.get(ch, "source")
      did = Map.get(ch, :document_id) || Map.get(ch, "document_id")
      content = Map.get(ch, :content) || Map.get(ch, "content")

      cond do
        not (is_binary(src) and not is_nil(did)) -> m
        Map.has_key?(m, did) -> m
        true -> Map.put(m, did, %{source: src, page: page_of(did, content)})
      end
    end)
  end

  defp merge_chunks(docs, _), do: docs

  defp emit_sources(conn, docs) do
    Enum.reduce(docs, conn, fn {doc_id, %{source: source, page: page}}, conn ->
      emit!(conn, %{
        type: "source-url",
        sourceId: doc_id,
        url: "/chat/documents/#{doc_id}",
        title: source,
        page: page
      })
    end)
  end

  # Page of a chunk = the number in the last `<!-- page: N -->` marker before the
  # chunk's text in the document markdown (pdf_to_md emits these). Defaults to 1.
  defp page_of(_doc_id, content) when not is_binary(content), do: 1

  defp page_of(doc_id, chunk_content) do
    probe = chunk_content |> String.trim() |> String.slice(0, 30)

    with %Document{content: doc} when is_binary(doc) <- Repo.get(Document, doc_id),
         true <- probe != "",
         {offset, _len} <- :binary.match(doc, probe) do
      doc |> binary_part(0, offset) |> last_page_marker()
    else
      _ -> 1
    end
  rescue
    _ -> 1
  end

  defp last_page_marker(prefix) do
    case Regex.scan(~r/<!-- page: (\d+) -->/, prefix, capture: :all_but_first) do
      [] -> 1
      matches -> matches |> List.last() |> hd() |> String.to_integer()
    end
  end

  # ---------------------------------------------------------------------------
  # GET /chat/documents/:id
  # ---------------------------------------------------------------------------

  def document(conn, %{"id" => id}) do
    case authorize(conn) do
      :ok ->
        case safe_get_document(id) do
          %Document{} = doc ->
            meta = doc.metadata || %{}

            json(conn, %{
              id: id,
              title: doc.title,
              source: doc.source,
              content_type: doc.content_type,
              content: doc.content,
              # Augmentation generated at/after ingestion, stored in metadata.
              summary: meta["summary"] || meta[:summary],
              suggestions: meta["suggestions"] || meta[:suggestions] || []
            })

          _ ->
            json_error(conn, 404, "document not found")
        end

      {:error, status, message} ->
        json_error(conn, status, message)
    end
  end

  # ---------------------------------------------------------------------------
  # GET /chat/documents?prefix=  — list documents (id, source, title, summary,
  # suggestions) under a source prefix, so a caller can surface the available
  # documents + their augmented summaries up front.
  # ---------------------------------------------------------------------------

  def documents(conn, params) do
    case authorize(conn) do
      :ok -> json(conn, %{documents: list_documents(fetch(params, "prefix"))})
      {:error, status, message} -> json_error(conn, status, message)
    end
  end

  # A non-empty prefix is REQUIRED — listing the whole corpus is not allowed.
  # LIKE wildcards in the prefix are escaped so it matches a literal prefix only,
  # and the result set is bounded.
  defp list_documents(prefix) when is_binary(prefix) and prefix != "" do
    import Ecto.Query

    pattern = escape_like(prefix) <> "%"

    from(d in Document,
      where: like(d.source, ^pattern),
      order_by: [asc: d.source],
      limit: 200,
      select: %{id: d.id, source: d.source, title: d.title, metadata: d.metadata}
    )
    |> Repo.all()
    |> Enum.map(fn d ->
      meta = d.metadata || %{}

      %{
        id: d.id,
        source: d.source,
        title: d.title,
        summary: meta["summary"] || meta[:summary],
        suggestions: meta["suggestions"] || meta[:suggestions] || []
      }
    end)
  rescue
    _ -> []
  end

  defp list_documents(_), do: []

  # Escape LIKE metacharacters so a caller-supplied prefix can't broaden the
  # match (e.g. "%"). Postgres LIKE treats backslash as the escape char.
  defp escape_like(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp safe_get_document(id) do
    Repo.get(Document, id)
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # SSE writer + shared plumbing (kept local + self-contained).
  # ---------------------------------------------------------------------------

  defp start_stream(conn) do
    conn
    |> put_resp_header("content-type", "text/event-stream")
    |> put_resp_header("cache-control", "no-cache")
    |> put_resp_header("connection", "keep-alive")
    |> send_chunked(200)
  end

  defp emit!(conn, event) when is_map(event), do: emit_raw!(conn, Jason.encode!(event))

  defp emit_raw!(conn, payload) do
    case chunk(conn, "data: #{payload}\n\n") do
      {:ok, conn} -> conn
      {:error, _reason} -> conn
    end
  end

  defp done(conn), do: emit_raw!(conn, "[DONE]")

  defp build_incoming(params) do
    case to_incoming(params) do
      %Incoming{content: content} = incoming when is_binary(content) and content != "" ->
        {:ok, incoming}

      %Incoming{} ->
        {:error, :empty_user_message}

      other ->
        {:error, {:invalid_incoming, other}}
    end
  rescue
    error -> {:error, error}
  end

  # Maps the request body ({messages, threadId, runId}) to an internal Incoming.
  # The question = the last user message's text. An optional caller-provided
  # `system` string is prepended as a per-run framing block (the caller owns its
  # content; this transport stays generic and just runs the answering agent).
  defp to_incoming(params) do
    Incoming.new(%{
      content: with_system(fetch(params, "system"), last_user_content(fetch(params, "messages") || [])),
      channel_id: fetch(params, "threadId") || "chat",
      message_id: fetch(params, "runId"),
      provider: :chat,
      metadata: %{}
    })
  end

  defp with_system(system, question)
       when is_binary(system) and system != "" and is_binary(question),
       do: system <> "\n\n" <> question

  defp with_system(_system, question), do: question

  defp last_user_content(messages) when is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      if fetch(msg, "role") == "user", do: message_text(fetch(msg, "content")), else: nil
    end)
  end

  defp last_user_content(_), do: nil

  defp message_text(text) when is_binary(text), do: text

  defp message_text(parts) when is_list(parts) do
    parts |> Enum.map(fn p -> fetch(p, "text") || "" end) |> Enum.join("")
  end

  defp message_text(_), do: nil

  defp authorize(conn) do
    case System.get_env("ZAQ_CHAT_TOKEN") do
      expected when is_binary(expected) and expected != "" ->
        case get_req_header(conn, "authorization") do
          ["Bearer " <> token] -> compare_token(token, expected)
          ["bearer " <> token] -> compare_token(token, expected)
          [] -> {:error, 401, "missing bearer token"}
          _ -> {:error, 403, "invalid bearer token"}
        end

      _ ->
        {:error, 503, "UIMessage transport not configured"}
    end
  end

  defp compare_token(got, expected) do
    if Plug.Crypto.secure_compare(got, expected),
      do: :ok,
      else: {:error, 403, "invalid bearer token"}
  end

  defp json_error(conn, status, message) do
    conn |> put_status(status) |> json(%{error: message})
  end

  defp error_message(:empty_user_message), do: "Aucun message utilisateur fourni."
  defp error_message(reason) when is_binary(reason), do: reason
  defp error_message(_reason), do: "Une erreur est survenue. Veuillez réessayer."

  defp fetch(map, key) when is_map(map), do: Map.get(map, key)
  defp fetch(_map, _key), do: nil
end
