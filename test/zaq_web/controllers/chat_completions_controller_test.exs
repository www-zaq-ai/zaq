defmodule ZaqWeb.ChatCompletionsControllerTest do
  @moduledoc """
  Acceptance tests for `POST /v1/chat/completions`, the OpenAI-compatible chat
  channel specified in `docs/services/chat-completions.md`. Test names quote
  the rule identifiers of that document.

  Only the LLM provider is replaced, by a scripted OpenAI-compatible server
  (`ScriptedLLM` below). Routing, the answering agent, the knowledge-base
  tools, People resolution and conversation storage are the real ones, so
  every assertion reads the HTTP response, the requests the model received,
  or records read back through public contexts.
  """

  # async: false: ZAQ_CHAT_TOKEN and the timing settings are VM-global, and the
  # agent runs in processes the test does not own (shared SQL sandbox).
  use ZaqWeb.ConnCase, async: false
  use ExUnitProperties

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.People
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Telemetry.{Buffer, Point}
  alias Zaq.Ingestion.{Chunk, ChunkLanguages, Document}
  alias Zaq.{Permissions, Repo}
  alias Zaq.SystemConfigFixtures
  alias Zaq.TestSupport.OpenAIStub

  @path "/v1/chat/completions"
  @token "test-chat-token"
  @embedding_dim 1536

  @usage %{"prompt_tokens" => 120, "completion_tokens" => 30, "total_tokens" => 150}

  @weather %{
    "type" => "function",
    "function" => %{
      "name" => "get_weather",
      "description" => "Current weather for a city",
      "parameters" => %{
        "type" => "object",
        "properties" => %{"city" => %{"type" => "string"}},
        "required" => ["city"]
      }
    }
  }

  # ---------------------------------------------------------------------------
  # Scripted LLM provider: an OpenAI-compatible Chat Completions server. Every
  # streamed model call is reported as {:llm_call, request} and answered with
  # the next scripted turn. Non-streamed calls are the knowledge-base query
  # translation, answered with the query unchanged for every language.
  # ---------------------------------------------------------------------------

  defmodule ScriptedLLM do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = read_body(conn)
      request = Jason.decode!(body)
      # Finch must not pool connections to a per-test server (see OpenAIStub).
      conn = put_resp_header(conn, "connection", "close")

      if request["stream"] == true do
        send(opts[:test_pid], {:llm_call, request})
        serve(conn, Agent.get_and_update(opts[:script], &pop/1), opts[:test_pid])
      else
        send_json(conn, 200, translation(request))
      end
    end

    defp pop([]), do: {nil, []}
    defp pop([turn | rest]), do: {turn, rest}

    defp serve(conn, nil, _test_pid),
      do: send_json(conn, 500, %{"error" => %{"message" => "unscripted model call"}})

    defp serve(conn, %{error_status: status}, _test_pid),
      do: send_json(conn, status, %{"error" => %{"message" => "provider failure"}})

    # A write that fails means the model's client closed the connection: it is
    # reported as :llm_stream_closed and the turn stops there.
    defp serve(conn, turn, test_pid) do
      # Wall-clock pacing is the behaviour under test where it is set (a model
      # that is silent, or that generates over time); the provider boundary
      # offers no other clock.
      if turn.delay_ms > 0, do: Process.sleep(turn.delay_ms)

      conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

      text =
        Enum.map(
          turn.reasoning,
          &{frame([choice(%{"reasoning_content" => &1}, nil)]), turn.pause_ms}
        ) ++
          Enum.map(turn.text, &{frame([choice(%{"content" => &1}, nil)]), turn.pause_ms})

      calls =
        if turn.tool_calls == [],
          do: [],
          else: [frame([choice(%{"tool_calls" => wire_calls(turn.tool_calls)}, nil)])]

      finish = if turn.tool_calls == [], do: "stop", else: "tool_calls"
      usage = if turn.usage, do: [frame([], %{"usage" => turn.usage})], else: []
      rest = calls ++ [frame([choice(%{}, finish)])] ++ usage ++ ["data: [DONE]\n\n"]

      Enum.reduce_while(text ++ Enum.map(rest, &{&1, 0}), conn, &write_frame(&1, &2, test_pid))
    end

    defp write_frame({data, pause_ms}, conn, test_pid) do
      case chunk(conn, data) do
        {:ok, conn} ->
          Process.sleep(pause_ms)
          {:cont, conn}

        {:error, _reason} ->
          send(test_pid, :llm_stream_closed)
          {:halt, conn}
      end
    end

    defp wire_calls(calls) do
      calls
      |> Enum.with_index()
      |> Enum.map(fn {{id, name, arguments}, index} ->
        %{
          "index" => index,
          "id" => id,
          "type" => "function",
          "function" => %{"name" => name, "arguments" => Jason.encode!(arguments)}
        }
      end)
    end

    defp choice(delta, finish), do: %{"index" => 0, "delta" => delta, "finish_reason" => finish}

    defp frame(choices, extra \\ %{}) do
      body =
        Map.merge(
          %{
            "id" => "chatcmpl-provider",
            "object" => "chat.completion.chunk",
            "created" => 0,
            "model" => "test-model",
            "choices" => choices
          },
          extra
        )

      "data: " <> Jason.encode!(body) <> "\n\n"
    end

    defp translation(%{"messages" => messages}) do
      %{"query" => query, "lexical_terms" => terms, "languages" => languages} =
        messages |> List.last() |> Map.fetch!("content") |> text() |> Jason.decode!()

      content =
        Jason.encode!(
          Map.new(languages, &{&1, %{"semantic_query" => query, "lexical_terms" => terms}})
        )

      %{
        "id" => "chatcmpl-translation",
        "object" => "chat.completion",
        "created" => 0,
        "model" => "test-model",
        "choices" => [
          %{
            "index" => 0,
            "message" => %{"role" => "assistant", "content" => content},
            "finish_reason" => "stop"
          }
        ]
      }
    end

    defp text(content) when is_binary(content), do: content
    defp text(parts), do: Enum.map_join(parts, "", &(&1["text"] || ""))

    defp send_json(conn, status, body) do
      conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
    end
  end

  # Scripted turns.
  defp answer(text, opts \\ []), do: turn(List.wrap(text), [], opts)
  defp call_tools(calls, opts \\ []), do: turn(Keyword.get(opts, :text, []), calls, opts)
  defp provider_error(status), do: %{error_status: status}

  defp turn(text, calls, opts) do
    %{
      text: text,
      tool_calls: calls,
      usage: Keyword.get(opts, :usage, @usage),
      reasoning: Keyword.get(opts, :reasoning, []),
      delay_ms: Keyword.get(opts, :delay_ms, 0),
      pause_ms: Keyword.get(opts, :pause_ms, 0)
    }
  end

  defp search(id, query),
    do: {id, "search_knowledge_base", %{"query" => query, "lexical_terms" => [query]}}

  setup_all do
    Sandbox.mode(Repo, :auto)

    try do
      Chunk.create_table(@embedding_dim)
    after
      Sandbox.mode(Repo, :manual)
    end

    :ok
  end

  setup do
    previous = System.get_env("ZAQ_CHAT_TOKEN")
    System.put_env("ZAQ_CHAT_TOKEN", @token)
    on_exit(fn -> restore_env("ZAQ_CHAT_TOKEN", previous) end)

    script = start_supervised!({Agent, fn -> [] end})
    port = free_port()

    start_supervised!(
      {Bandit, plug: {ScriptedLLM, test_pid: self(), script: script}, scheme: :http, port: port}
    )

    "http://127.0.0.1:#{port}/v1"
    |> OpenAIStub.llm_config()
    |> Map.new()
    |> Map.merge(%{max_context_window: 128_000, distance_threshold: 1.2})
    |> SystemConfigFixtures.seed_llm_config()

    ChunkLanguages.invalidate()

    {:ok, script: script}
  end

  defp script(%{script: script}, turns), do: Agent.update(script, fn _ -> turns end)

  # ---------------------------------------------------------------------------
  # HTTP helpers.
  # ---------------------------------------------------------------------------

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        "model" => "zaq-chat",
        "user" => "user-a",
        "conversation_id" => Ecto.UUID.generate(),
        "messages" => [user("Bonjour")]
      },
      overrides
    )
  end

  defp user(content), do: %{"role" => "user", "content" => content}

  defp chat(body, headers \\ [{"authorization", "Bearer #{@token}"}]) do
    Enum.reduce(headers, put_req_header(build_conn(), "content-type", "application/json"), fn
      {key, value}, conn -> put_req_header(conn, key, value)
    end)
    |> post(@path, body)
  end

  defp stream(overrides), do: overrides |> Map.put("stream", true) |> request() |> chat()

  # `data:` frames of an SSE body, decoded; comments and the [DONE] sentinel
  # are dropped.
  defp data_frames(sse) do
    sse
    |> String.split("\n\n", trim: true)
    |> Enum.reject(&(String.starts_with?(&1, ":") or &1 == "data: [DONE]"))
    |> Enum.map(fn "data: " <> json -> Jason.decode!(json) end)
  end

  defp content_deltas(frames) do
    Enum.flat_map(frames, fn
      %{"choices" => [%{"delta" => %{"content" => content}} | _]} -> [content]
      _ -> []
    end)
  end

  defp index_of(sse, pattern) do
    case :binary.match(sse, pattern) do
      {index, _} -> index
      :nomatch -> flunk("#{inspect(pattern)} not found in #{inspect(sse)}")
    end
  end

  defp llm_calls(acc \\ []) do
    receive do
      {:llm_call, request} -> llm_calls([request | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tool_names(llm_call), do: Enum.map(llm_call["tools"] || [], & &1["function"]["name"])

  defp last_user_text(llm_call) do
    llm_call["messages"]
    |> Enum.filter(&(&1["role"] == "user"))
    |> List.last()
    |> Map.fetch!("content")
  end

  defp model_input(llm_call), do: Jason.encode!(llm_call["messages"])

  defp persisted(conversation_id) do
    conversation_id
    |> Conversations.get_conversation()
    |> Conversations.list_messages()
    |> Enum.map(&{&1.role, &1.content})
  end

  defp with_timing(settings) do
    for {key, value} <- settings do
      previous = Application.get_env(:zaq, key)
      Application.put_env(:zaq, key, value)
      on_exit(fn -> restore_app_env(key, previous) end)
    end
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:zaq, key)
  defp restore_app_env(key, value), do: Application.put_env(:zaq, key, value)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  # Streams `body` through a real HTTP listener and closes the socket once the
  # first content delta arrived: a closed connection is the behaviour under
  # test, and the Plug test adapter has no socket to close.
  defp disconnect_after_content(body) do
    port = free_port()

    start_supervised!(
      Supervisor.child_spec({Bandit, plug: ZaqWeb.Endpoint, scheme: :http, port: port},
        id: :chat_listener
      )
    )

    json = body |> Map.put("stream", true) |> Jason.encode!()
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])

    :ok =
      :gen_tcp.send(socket, [
        "POST #{@path} HTTP/1.1\r\nhost: localhost\r\n",
        "authorization: Bearer #{@token}\r\ncontent-type: application/json\r\n",
        "content-length: #{byte_size(json)}\r\n\r\n",
        json
      ])

    received = receive_until(socket, ~s("content":), "")
    :ok = :gen_tcp.close(socket)
    received
  end

  defp receive_until(socket, pattern, acc) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> data
    if String.contains?(acc, pattern), do: acc, else: receive_until(socket, pattern, acc)
  end

  # Telemetry points one request records: each metric with the dimensions
  # that do not depend on the request itself.
  defp recorded_metrics(fun) do
    Buffer.flush()
    Repo.delete_all(Point)
    fun.()
    :ok = Buffer.flush()

    Repo.all(Point)
    |> MapSet.new(&{&1.metric_key, Map.drop(&1.dimensions, ["conversation_id", "channel_id"])})
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)
    port
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  describe "authentication" do
    test "AUTH-3: fails closed with 503 while no token is configured" do
      for unset <- [nil, ""] do
        if unset,
          do: System.put_env("ZAQ_CHAT_TOKEN", unset),
          else: System.delete_env("ZAQ_CHAT_TOKEN")

        assert %{"error" => %{"message" => message}} = json_response(chat(request()), 503)
        assert message =~ "not configured"
      end

      assert llm_calls() == []
    end

    test "AUTH-1/AUTH-2: 401 without a bearer token or with the wrong one" do
      assert json_response(chat(request(), []), 401) == %{
               "error" => %{"message" => "missing bearer token"}
             }

      assert json_response(chat(request(), [{"authorization", "Bearer nope"}]), 401) == %{
               "error" => %{"message" => "invalid bearer token"}
             }

      assert llm_calls() == []
    end
  end

  # ---------------------------------------------------------------------------
  # Request validation
  # ---------------------------------------------------------------------------

  describe "request validation" do
    test "REQ-1..3: malformed requests are rejected before the model is called" do
      many = List.duplicate(user("x"), 201)

      for {overrides, status, message} <- [
            {%{"messages" => "Bonjour"}, 400, "messages must be an array"},
            {%{"messages" => [%{"role" => "system", "content" => "x"}]}, 400,
             "no user message provided"},
            {%{"messages" => [user("")]}, 400, "no user message provided"},
            {%{"messages" => many}, 413, "too many messages (max 200)"},
            {%{"user" => ""}, 400, "user (owner id) is required"},
            {%{"conversation_id" => nil}, 400, "conversation_id is required"},
            {%{"conversation_id" => "not-a-uuid"}, 400, "invalid conversation_id"}
          ] do
        conn = chat(request(overrides))

        assert json_response(conn, status) == %{"error" => %{"message" => message}},
               "#{inspect(overrides)} -> #{conn.status} #{conn.resp_body}"
      end

      assert llm_calls() == []
    end

    test "REQ-1: a user message may be an array of text parts", ctx do
      script(ctx, [answer("Bonjour !")])

      parts = [%{"type" => "text", "text" => "Bon"}, %{"type" => "text", "text" => "jour"}]
      assert json_response(chat(request(%{"messages" => [user(parts)]})), 200)

      assert [call] = llm_calls()
      assert last_user_text(call) =~ ~r/Bonjour\z/
    end
  end

  # ---------------------------------------------------------------------------
  # Conversations: ownership, history, persistence
  # ---------------------------------------------------------------------------

  describe "conversations" do
    test "CONV-1/CONV-4: the first request opens a chat conversation owned by `user` and stores the turn",
         ctx do
      script(ctx, [answer("Le budget a été voté.")])
      conversation_id = Ecto.UUID.generate()

      assert json_response(
               chat(
                 request(%{
                   "conversation_id" => conversation_id,
                   "messages" => [user("Quel budget ?")]
                 })
               ),
               200
             )

      assert %{channel_user_id: "user-a", channel_type: "chat"} =
               Conversations.get_conversation(conversation_id)

      assert [{"user", "Quel budget ?"}, {"assistant", answer}] = persisted(conversation_id)
      assert answer =~ "Le budget a été voté."
    end

    test "CONV-2: another user cannot read or append to a conversation", ctx do
      script(ctx, [answer("Réponse privée.")])
      conversation_id = Ecto.UUID.generate()
      assert json_response(chat(request(%{"conversation_id" => conversation_id})), 200)
      _ = llm_calls()

      conn = chat(request(%{"user" => "user-b", "conversation_id" => conversation_id}))

      assert json_response(conn, 403) == %{
               "error" => %{"message" => "conversation does not belong to user"}
             }

      assert llm_calls() == []
      assert length(persisted(conversation_id)) == 2
    end

    test "CONV-2: a conversation of another channel is never resolved, even for the same user id" do
      {:ok, bo_conversation} =
        Conversations.create_conversation(%{channel_user_id: "user-a", channel_type: "bo"})

      conn = chat(request(%{"conversation_id" => bo_conversation.id}))

      assert json_response(conn, 403) == %{
               "error" => %{"message" => "conversation does not belong to user"}
             }

      assert llm_calls() == []
    end

    test "CONV-3: the model receives the stored history; the caller sends only the new message",
         ctx do
      script(ctx, [answer("Première réponse."), answer("Deuxième réponse.")])
      conversation_id = Ecto.UUID.generate()
      first = request(%{"conversation_id" => conversation_id, "messages" => [user("Q1 ?")]})
      assert json_response(chat(first), 200)

      # A client resending (even altering) earlier turns does not override the
      # stored history.
      second =
        request(%{
          "conversation_id" => conversation_id,
          "messages" => [
            user("Q1 ?"),
            %{"role" => "assistant", "content" => "Réponse inventée par le client."},
            user("Q2 ?")
          ]
        })

      assert json_response(chat(second), 200)

      assert [_first_call, second_call] = llm_calls()
      input = model_input(second_call)
      assert input =~ "Q1 ?"
      assert input =~ "Première réponse."
      refute input =~ "Réponse inventée par le client."
      assert last_user_text(second_call) =~ ~r/Q2 \?\z/
    end

    test "CONV-3: conversations of the same user do not share history", ctx do
      script(ctx, [answer("Réponse A."), answer("Réponse B.")])
      assert json_response(chat(request(%{"messages" => [user("Secret de A")]})), 200)
      assert json_response(chat(request(%{"messages" => [user("Question B")]})), 200)

      assert [_a, b] = llm_calls()
      refute model_input(b) =~ "Secret de A"
      refute model_input(b) =~ "Réponse A."
    end

    test "REQ-4: a system message frames the run but is never stored", ctx do
      script(ctx, [answer("Oui.")])
      conversation_id = Ecto.UUID.generate()

      body =
        request(%{
          "conversation_id" => conversation_id,
          "messages" => [%{"role" => "system", "content" => "Sois bref."}, user("Quel budget ?")]
        })

      assert json_response(chat(body), 200)

      assert [call] = llm_calls()
      assert last_user_text(call) =~ ~r/Sois bref\.\n\nQuel budget \?\z/
      assert [{"user", "Quel budget ?"}, {"assistant", _}] = persisted(conversation_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Identity and the People directory
  # ---------------------------------------------------------------------------

  describe "identity" do
    test "ID-1/ID-2: one Person per caller user id, named from zaq_user.name and reused", ctx do
      script(ctx, [answer("Un."), answer("Deux.")])
      user_id = "supabase-" <> Ecto.UUID.generate()
      identity = %{"user" => user_id, "zaq_user" => %{"name" => "Jeanne Martin"}}

      assert json_response(chat(request(identity)), 200)
      assert {:ok, first} = People.match_by_channel("chat", user_id)
      assert first.full_name == "Jeanne Martin"

      assert json_response(chat(request(identity)), 200)
      assert {:ok, second} = People.match_by_channel("chat", user_id)
      assert second.id == first.id
      assert [%{platform: "chat", channel_identifier: ^user_id}] = second.channels
    end

    test "ID-2: a Person first seen without a name is renamed when a name arrives", ctx do
      script(ctx, [answer("Un."), answer("Deux.")])
      user_id = "supabase-" <> Ecto.UUID.generate()

      assert json_response(chat(request(%{"user" => user_id})), 200)
      assert {:ok, seeded} = People.match_by_channel("chat", user_id)

      named = %{"user" => user_id, "zaq_user" => %{"name" => "Paul Durand"}}
      assert json_response(chat(request(named)), 200)
      assert {:ok, renamed} = People.match_by_channel("chat", user_id)
      assert renamed.id == seeded.id
      assert renamed.full_name == "Paul Durand"
    end

    @tag :security
    test "ID-3: an email in the request can never select or modify an existing Person", ctx do
      script(ctx, [answer("Bonjour.")])

      {:ok, victim} =
        People.create_person(%{
          full_name: "Marie Dupont",
          email: "marie@client.com",
          team_ids: [1234]
        })

      user_id = "supabase-" <> Ecto.UUID.generate()

      claim = %{
        "user" => user_id,
        "zaq_user" => %{"name" => "Attacker", "email" => "marie@client.com"}
      }

      assert json_response(chat(request(claim)), 200)

      assert {:ok, chat_person} = People.match_by_channel("chat", user_id)
      refute chat_person.id == victim.id
      assert chat_person.team_ids in [nil, []]

      reloaded = Repo.get!(Zaq.Accounts.Person, victim.id)
      assert reloaded.full_name == "Marie Dupont"
      assert reloaded.team_ids == [1234]
    end
  end

  # ---------------------------------------------------------------------------
  # Non-streaming responses
  # ---------------------------------------------------------------------------

  describe "non-streaming response" do
    test "RESP-1/RESP-2: a chat.completion with the cleaned answer", ctx do
      script(ctx, [answer(["Réponse  \n", "générée. [[source:doc.pdf|p3]]"])])

      resp = json_response(chat(request(%{"model" => "mon-modele"})), 200)

      assert %{
               "id" => "chatcmpl-" <> _,
               "object" => "chat.completion",
               "created" => created,
               "model" => "mon-modele",
               "choices" => [
                 %{
                   "index" => 0,
                   "finish_reason" => "stop",
                   "message" => %{"role" => "assistant", "content" => "Réponse\ngénérée."}
                 }
               ],
               "zaq_sources" => []
             } = resp

      assert is_integer(created)
    end

    test "REQ-5: model defaults to zaq-chat and never selects the LLM", ctx do
      script(ctx, [answer("Oui.")])
      resp = json_response(chat(Map.delete(request(), "model")), 200)

      assert resp["model"] == "zaq-chat"
      assert [%{"model" => "test-model"}] = llm_calls()
    end

    test "USAGE-1: usage sums the provider-reported usage of every model call of the request",
         ctx do
      script(ctx, [
        call_tools([search("k1", "budget")],
          usage: %{"prompt_tokens" => 100, "completion_tokens" => 10, "total_tokens" => 110}
        ),
        answer("Le budget.",
          usage: %{"prompt_tokens" => 200, "completion_tokens" => 20, "total_tokens" => 220}
        )
      ])

      resp = json_response(chat(request()), 200)

      assert resp["usage"] == %{
               "prompt_tokens" => 300,
               "completion_tokens" => 30,
               "total_tokens" => 330
             }
    end

    test "USAGE-3: usage is omitted, never estimated, when the provider reports none", ctx do
      script(ctx, [answer("Sans compteurs.", usage: nil)])

      resp = json_response(chat(request()), 200)
      assert resp["choices"] |> hd() |> get_in(["message", "content"]) == "Sans compteurs."
      refute Map.has_key?(resp, "usage")
    end

    test "ERR-1: a failing model call is a 502 with an OpenAI error object", ctx do
      script(ctx, [provider_error(500), provider_error(500), provider_error(500)])

      assert %{"error" => %{"message" => message}} = json_response(chat(request()), 502)
      assert is_binary(message) and message != ""
    end
  end

  # ---------------------------------------------------------------------------
  # Streaming responses
  # ---------------------------------------------------------------------------

  describe "streaming response" do
    test "SSE-1/SSE-2/SSE-4: role frame first, complete chunks, terminal stop chunk, [DONE]",
         ctx do
      script(ctx, [answer(["Réponse ", "générée."])])

      conn = stream(%{})
      sse = response(conn, 200)
      assert [content_type | _] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/event-stream"

      frames = data_frames(sse)
      assert [%{"id" => "chatcmpl-" <> _ = id} | _] = frames

      for frame <- frames do
        assert %{
                 "id" => ^id,
                 "object" => "chat.completion.chunk",
                 "created" => created,
                 "model" => "zaq-chat",
                 "choices" => [%{"index" => 0, "delta" => delta}]
               } = frame

        assert is_integer(created) and is_map(delta)
      end

      assert hd(frames)["choices"] == [
               %{"index" => 0, "delta" => %{"role" => "assistant"}, "finish_reason" => nil}
             ]

      assert List.last(frames)["choices"] == [
               %{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}
             ]

      assert Enum.join(content_deltas(frames)) == "Réponse générée."
      assert String.ends_with?(sse, "data: [DONE]\n\n")
      refute Enum.any?(frames, &Map.has_key?(&1, "zaq_sources"))
      refute Enum.any?(frames, &Map.has_key?(&1, "usage"))
    end

    test "SSE-3: content is streamed while the model generates", ctx do
      # Each part exceeds the executor's 20-character flush threshold and
      # arrives 150 ms after the previous one, so it is forwarded on its own.
      script(ctx, [
        answer(
          [
            "Le conseil municipal a voté ",
            "le budget primitif à l'unanimité ",
            "lors de la séance du 18 juin."
          ],
          pause_ms: 150
        )
      ])

      deltas = stream(%{}) |> response(200) |> data_frames() |> content_deltas()

      assert length(deltas) > 1

      assert Enum.join(deltas) ==
               "Le conseil municipal a voté le budget primitif à l'unanimité lors de la séance du 18 juin."
    end

    property "SSE-3: however the model splits its output, the streamed text is the cleaned answer, once",
             ctx do
      check all(
              words <-
                list_of(string(?a..?z, min_length: 1, max_length: 8),
                  min_length: 2,
                  max_length: 12
                ),
              cited <- list_of(boolean(), length: length(words)),
              splits <- list_of(integer(1..6), min_length: 1, max_length: 8),
              max_runs: 15
            ) do
        raw =
          words
          |> Enum.zip(cited)
          |> Enum.map_join(" ", fn
            {word, true} -> "#{word} [[source:doc-#{word}.md|p1]]"
            {word, false} -> word
          end)

        expected = Enum.join(words, " ")
        script(ctx, [answer(split(raw, splits), usage: nil)])

        deltas = stream(%{}) |> response(200) |> data_frames() |> content_deltas()

        assert Enum.join(deltas) == expected
        refute Enum.any?(deltas, &String.contains?(&1, "[["))
        _ = llm_calls()
      end
    end

    test "SSE-3: text streamed before an internal tool call stays; the final answer follows once",
         ctx do
      final = "Le conseil a voté le budget."

      script(ctx, [
        call_tools([search("k1", "budget")], text: ["Je cherche dans les documents."]),
        answer(["Le conseil ", "a voté le budget."])
      ])

      deltas = stream(%{}) |> response(200) |> data_frames() |> content_deltas()
      joined = Enum.join(deltas)

      assert String.ends_with?(joined, final)
      assert joined |> String.split(final) |> length() == 2
    end

    test "USAGE-2: include_usage adds a usage chunk with empty choices after the terminal chunk",
         ctx do
      script(ctx, [
        call_tools([search("k1", "budget")],
          usage: %{"prompt_tokens" => 100, "completion_tokens" => 10, "total_tokens" => 110}
        ),
        answer("Le budget.",
          usage: %{"prompt_tokens" => 200, "completion_tokens" => 20, "total_tokens" => 220}
        )
      ])

      frames =
        %{"stream_options" => %{"include_usage" => true}}
        |> stream()
        |> response(200)
        |> data_frames()

      assert [
               %{"choices" => [%{"finish_reason" => "stop"}]},
               %{"object" => "chat.completion.chunk", "choices" => [], "usage" => usage}
             ] = Enum.take(frames, -2)

      assert usage == %{"prompt_tokens" => 300, "completion_tokens" => 30, "total_tokens" => 330}
    end

    test "USAGE-3: include_usage sends no usage chunk when the provider reports none", ctx do
      script(ctx, [answer("Sans compteurs.", usage: nil)])

      frames =
        %{"stream_options" => %{"include_usage" => true}}
        |> stream()
        |> response(200)
        |> data_frames()

      refute Enum.any?(frames, &Map.has_key?(&1, "usage"))

      assert List.last(frames)["choices"] == [
               %{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}
             ]
    end

    test "SSE-5: keepalive comments flow while the model is silent, after the role frame", ctx do
      with_timing(chat_keepalive_ms: 20)
      script(ctx, [answer("Enfin.", delay_ms: 300)])

      sse = stream(%{}) |> response(200)

      role_at = index_of(sse, ~s("delta":{"role":"assistant"}))
      keepalive_at = index_of(sse, ": keepalive\n\n")
      content_at = index_of(sse, ~s("content":"Enfin."))
      assert role_at < keepalive_at and keepalive_at < content_at
    end

    test "SSE-5: non-streaming responses never carry keepalive bytes", ctx do
      with_timing(chat_keepalive_ms: 20)
      script(ctx, [answer("Enfin.", delay_ms: 300)])

      conn = chat(request())

      assert json_response(conn, 200)["choices"] |> hd() |> get_in(["message", "content"]) ==
               "Enfin."

      refute conn.resp_body =~ "keepalive"
    end
  end

  # ---------------------------------------------------------------------------
  # Errors and timeouts
  # ---------------------------------------------------------------------------

  describe "errors and timeouts" do
    test "ERR-2: a silent run times out with a 502 when not streaming", ctx do
      with_timing(chat_result_timeout_ms: 100)
      script(ctx, [answer("Trop tard.", delay_ms: 600)])

      assert json_response(chat(request()), 502) == %{
               "error" => %{"message" => "The answer took too long. Please try again."}
             }
    end

    test "ERR-2/ERR-3: when streaming, the error travels in-band and keepalives do not extend the idle timeout",
         ctx do
      with_timing(chat_keepalive_ms: 20, chat_result_timeout_ms: 150)
      script(ctx, [answer("Trop tard.", delay_ms: 600)])

      sse = stream(%{}) |> response(200)
      assert sse =~ ": keepalive\n\n"

      assert %{
               "object" => "chat.completion.chunk",
               "choices" => [
                 %{"index" => 0, "delta" => %{"content" => message}, "finish_reason" => "stop"}
               ],
               "error" => %{"message" => message, "type" => "server_error"}
             } = sse |> data_frames() |> List.last()

      assert message =~ "took too long"
      assert String.ends_with?(sse, "data: [DONE]\n\n")
    end

    test "ERR-3: each streamed delta restarts the idle timeout", ctx do
      # The answer takes about three idle timeouts to generate, with a delta
      # well within each one. Parts exceed the executor's 20-character flush
      # threshold so each one is forwarded as it arrives.
      with_timing(chat_result_timeout_ms: 700)

      parts = [
        "Le conseil municipal s'est réuni ",
        "le 18 juin pour examiner le budget, ",
        "qui a été adopté après débat ",
        "par vingt-trois voix contre six, ",
        "avec deux abstentions en séance ",
        "et une suspension de dix minutes."
      ]

      script(ctx, [answer(parts, pause_ms: 300)])

      deltas = stream(%{}) |> response(200) |> data_frames() |> content_deltas()
      assert Enum.join(deltas) == parts |> Enum.join() |> String.trim()
    end

    test "ERR-1: a failing model call is reported in-band when streaming", ctx do
      script(ctx, [provider_error(500), provider_error(500), provider_error(500)])

      sse = stream(%{}) |> response(200)

      assert %{
               "error" => %{"type" => "server_error"},
               "choices" => [%{"finish_reason" => "stop"}]
             } =
               sse |> data_frames() |> List.last()

      assert String.ends_with?(sse, "data: [DONE]\n\n")
    end
  end

  # ---------------------------------------------------------------------------
  # Citations and retrieval scope
  # ---------------------------------------------------------------------------

  describe "citations" do
    setup do
      SystemConfigFixtures.seed_embedding_config(%{
        model: "test-model",
        dimension: "#{@embedding_dim}"
      })

      Req.Test.set_req_test_to_shared()
      on_exit(fn -> Req.Test.set_req_test_to_private() end)

      Req.Test.stub(Zaq.Embedding.Client, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"embedding" => List.duplicate(0.1, @embedding_dim)}]})
      end)

      minutes =
        document("pv/2025-06-18.md", "Le conseil a voté le budget.", public?: true, page: 3)

      press = document("presse/communique.md", "Communiqué de presse.", public?: true)
      _salaries = document("rh/salaires.md", "Salaires confidentiels.", public?: false)

      %{minutes: minutes, press: press}
    end

    defp document(source, content, opts) do
      {:ok, doc} =
        Document.upsert(%{source: source, content: content, content_type: "markdown"})

      if opts[:public?], do: {:ok, _} = Permissions.grant_public(doc)

      metadata = if opts[:page], do: %{"start" => "P#{opts[:page]}|L1"}, else: %{}

      %Chunk{}
      |> Chunk.changeset(%{
        document_id: doc.id,
        content: content,
        chunk_index: 0,
        section_path: ["test"],
        metadata: metadata,
        embedding: Pgvector.HalfVector.new(List.duplicate(0.1, @embedding_dim)),
        language: "french"
      })
      |> Repo.insert!()

      ChunkLanguages.invalidate()
      doc
    end

    defp tool_results(llm_call) do
      llm_call["messages"]
      |> Enum.filter(&(&1["role"] == "tool"))
      |> Enum.map_join("\n", &to_string(&1["content"]))
    end

    test "CITE-1/ID-4: retrieved documents are cited; documents the caller may not read are not",
         %{minutes: minutes, press: press} = ctx do
      script(ctx, [
        call_tools([search("k1", "budget")]),
        answer("Le budget a été voté. [[source:pv/2025-06-18.md|p3]]")
      ])

      resp = json_response(chat(request()), 200)

      assert resp["choices"] |> hd() |> get_in(["message", "content"]) == "Le budget a été voté."

      assert Enum.sort_by(resp["zaq_sources"], & &1["sourceId"]) ==
               Enum.sort_by(
                 [
                   %{"sourceId" => minutes.id, "title" => "pv/2025-06-18.md", "page" => 3},
                   %{"sourceId" => press.id, "title" => "presse/communique.md", "page" => nil}
                 ],
                 & &1["sourceId"]
               )

      # The model itself never saw the private document.
      assert [_search_call, answer_call] = llm_calls()
      assert tool_results(answer_call) =~ "Le conseil a voté le budget."
      refute tool_results(answer_call) =~ "Salaires confidentiels."
    end

    test "ID-5: source_filter narrows retrieval to the given folders",
         %{minutes: minutes} = ctx do
      script(ctx, [call_tools([search("k1", "budget")]), answer("Le budget a été voté.")])

      resp = json_response(chat(request(%{"source_filter" => ["pv"]})), 200)

      assert [%{"sourceId" => id}] = resp["zaq_sources"]
      assert id == minutes.id

      assert [_search_call, answer_call] = llm_calls()
      refute tool_results(answer_call) =~ "Communiqué de presse."
    end

    test "CITE-2: when streaming, citations ride one empty-delta chunk before the terminal chunk",
         %{minutes: minutes} = ctx do
      script(ctx, [call_tools([search("k1", "budget")]), answer("Le budget a été voté.")])

      frames = %{"source_filter" => "pv"} |> stream() |> response(200) |> data_frames()

      assert [
               %{
                 "object" => "chat.completion.chunk",
                 "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => nil}],
                 "zaq_sources" => [%{"sourceId" => id, "page" => 3}]
               },
               %{"choices" => [%{"finish_reason" => "stop"}]}
             ] = Enum.take(frames, -2)

      assert id == minutes.id
    end
  end

  # ---------------------------------------------------------------------------
  # Caller-executed tools
  # ---------------------------------------------------------------------------

  describe "caller tools" do
    test "TOOL-1/TOOL-2/TOOL-6: invalid tool requests are rejected before the model is called" do
      call = %{
        "id" => "call_1",
        "type" => "function",
        "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
      }

      q = user("Quel temps ?")

      tools =
        List.duplicate(@weather, 129)
        |> Enum.with_index(&put_in(&1, ["function", "name"], "t#{&2}"))

      for {overrides, message} <- [
            {%{"tools" => "get_weather"}, "tools must be an array"},
            {%{"tools" => [%{"type" => "function"}]}, "each tool must be"},
            {%{"tools" => [%{"type" => "retrieval", "function" => %{"name" => "x"}}]},
             "each tool must be"},
            {%{"tools" => [@weather, @weather]}, "tool names must be unique"},
            {%{"tools" => tools}, "too many tools (max 128)"},
            {%{"tools" => [@weather], "tool_choice" => "sometimes"}, "invalid tool_choice"},
            {%{
               "tools" => [@weather],
               "tool_choice" => %{"type" => "function", "function" => %{"name" => "other"}}
             }, "tool_choice names a function that is not in tools"},
            {%{
               "messages" => [q, %{"role" => "tool", "tool_call_id" => "nope", "content" => "x"}]
             }, "tool message references an unknown tool_call_id"},
            {%{"messages" => [q, %{"role" => "assistant", "tool_calls" => [call]}]},
             "every tool_call needs a tool message answering it"},
            {%{
               "messages" => [
                 q,
                 %{
                   "role" => "assistant",
                   "tool_calls" => [put_in(call, ["function", "arguments"], "[1]")]
                 },
                 %{"role" => "tool", "tool_call_id" => "call_1", "content" => "x"}
               ]
             }, "tool_calls arguments must be a JSON object string"},
            {%{
               "messages" => [
                 q,
                 %{"role" => "assistant", "tool_calls" => [Map.delete(call, "id")]}
               ]
             }, "each tool_call needs an id and function.name"}
          ] do
        conn = chat(request(overrides))

        assert %{"error" => %{"message" => actual}} = json_response(conn, 400)
        assert actual =~ message, "#{inspect(overrides)} -> #{actual}"
      end

      assert llm_calls() == []
    end

    test "TOOL-3/TOOL-4/TOOL-5: the model sees caller and internal tools; only caller calls are returned",
         ctx do
      script(ctx, [
        call_tools([search("k1", "météo")]),
        call_tools([{"call_1", "get_weather", %{"city" => "Paris"}}])
      ])

      body = request(%{"tools" => [@weather], "tool_choice" => "required"})
      resp = json_response(chat(body), 200)

      assert resp["choices"] == [
               %{
                 "index" => 0,
                 "finish_reason" => "tool_calls",
                 "message" => %{
                   "role" => "assistant",
                   "content" => nil,
                   "tool_calls" => [
                     %{
                       "id" => "call_1",
                       "type" => "function",
                       "function" => %{
                         "name" => "get_weather",
                         "arguments" => ~s({"city":"Paris"})
                       }
                     }
                   ]
                 }
               }
             ]

      assert [first, second] = llm_calls()
      assert "get_weather" in tool_names(first)
      assert "search_knowledge_base" in tool_names(first)

      assert Enum.find(first["tools"], &(&1["function"]["name"] == "get_weather"))["function"]
             |> Map.take(["description", "parameters"]) ==
               Map.take(@weather["function"], ["description", "parameters"])

      # tool_choice constrains the first model call only: once ZAQ's own tool
      # answered, the model is free again.
      assert first["tool_choice"] == "required"
      refute second["tool_choice"] == "required"
      assert Enum.any?(second["messages"], &(&1["role"] == "tool" and &1["tool_call_id"] == "k1"))
    end

    test "TOOL-3: a named tool_choice reaches the model as a named function choice", ctx do
      script(ctx, [call_tools([{"call_1", "get_weather", %{"city" => "Paris"}}])])

      choice = %{"type" => "function", "function" => %{"name" => "get_weather"}}
      assert json_response(chat(request(%{"tools" => [@weather], "tool_choice" => choice})), 200)

      assert [%{"tool_choice" => ^choice}] = llm_calls()
    end

    test "TOOL-3: tool_choice none keeps the caller tools away from the model", ctx do
      script(ctx, [answer("Il fait beau.")])

      resp = json_response(chat(request(%{"tools" => [@weather], "tool_choice" => "none"})), 200)

      assert [%{"finish_reason" => "stop", "message" => %{"content" => "Il fait beau."}}] =
               resp["choices"]

      assert [call] = llm_calls()
      refute "get_weather" in tool_names(call)
    end

    test "TOOL-4: when streaming, caller tool calls ride one delta.tool_calls chunk", ctx do
      script(ctx, [
        call_tools([{"call_1", "get_weather", %{"city" => "Paris"}}],
          usage: %{"prompt_tokens" => 7, "completion_tokens" => 3, "total_tokens" => 10}
        )
      ])

      sse =
        %{"tools" => [@weather], "stream_options" => %{"include_usage" => true}}
        |> stream()
        |> response(200)

      frames = data_frames(sse)

      assert [
               %{
                 "choices" => [
                   %{
                     "delta" => %{
                       "tool_calls" => [
                         %{
                           "index" => 0,
                           "id" => "call_1",
                           "type" => "function",
                           "function" => %{
                             "name" => "get_weather",
                             "arguments" => ~s({"city":"Paris"})
                           }
                         }
                       ]
                     },
                     "finish_reason" => nil
                   }
                 ]
               },
               %{"choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "tool_calls"}]},
               %{
                 "choices" => [],
                 "usage" => %{
                   "prompt_tokens" => 7,
                   "completion_tokens" => 3,
                   "total_tokens" => 10
                 }
               }
             ] = Enum.take(frames, -3)

      refute sse =~ ~s("finish_reason":"stop")
      assert String.ends_with?(sse, "data: [DONE]\n\n")
    end

    test "TOOL-7/TOOL-8: a caller tool round trip continues the turn and stores it once", ctx do
      conversation_id = Ecto.UUID.generate()
      base = %{"conversation_id" => conversation_id, "tools" => [@weather]}

      script(ctx, [
        answer("Bonjour !"),
        call_tools([{"call_1", "get_weather", %{"city" => "Paris"}}],
          usage: %{"prompt_tokens" => 50, "completion_tokens" => 5, "total_tokens" => 55}
        ),
        answer("Il fait 21 degrés à Paris.",
          usage: %{"prompt_tokens" => 60, "completion_tokens" => 6, "total_tokens" => 66}
        )
      ])

      # An earlier, plain turn of the same conversation.
      assert json_response(chat(request(Map.put(base, "messages", [user("Bonjour")]))), 200)

      question = user("Quel temps à Paris ?")
      paused = json_response(chat(request(Map.put(base, "messages", [question]))), 200)
      assert [%{"finish_reason" => "tool_calls"}] = paused["choices"]

      assert paused["usage"] == %{
               "prompt_tokens" => 50,
               "completion_tokens" => 5,
               "total_tokens" => 55
             }

      # Nothing of the paused turn is stored.
      assert [{"user", "Bonjour"}, {"assistant", _}] = persisted(conversation_id)

      [tool_call] = paused["choices"] |> hd() |> get_in(["message", "tool_calls"])

      follow_up =
        Map.put(base, "messages", [
          question,
          %{"role" => "assistant", "content" => nil, "tool_calls" => [tool_call]},
          %{"role" => "tool", "tool_call_id" => "call_1", "content" => ~s({"temp":21})}
        ])

      resp = json_response(chat(request(follow_up)), 200)

      assert [
               %{
                 "finish_reason" => "stop",
                 "message" => %{"role" => "assistant", "content" => "Il fait 21 degrés à Paris."}
               }
             ] = resp["choices"]

      assert resp["usage"] == %{
               "prompt_tokens" => 60,
               "completion_tokens" => 6,
               "total_tokens" => 66
             }

      assert [_plain, paused_call, follow_up_call] = llm_calls()

      # Stored history reaches the tool path too.
      assert model_input(paused_call) =~ "Bonjour !"

      # The exchange is replayed to the model as native tool messages, after
      # the question.
      assert [
               %{"role" => "user"},
               %{
                 "role" => "assistant",
                 "tool_calls" => [
                   %{
                     "id" => "call_1",
                     "function" => %{"name" => "get_weather", "arguments" => args}
                   }
                 ]
               },
               %{"role" => "tool", "tool_call_id" => "call_1", "content" => ~s({"temp":21})}
             ] = Enum.take(follow_up_call["messages"], -3)

      assert Jason.decode!(args) == %{"city" => "Paris"}
      assert last_user_text(follow_up_call) =~ "Quel temps à Paris ?"

      assert [
               {"user", "Bonjour"},
               {"assistant", _},
               {"user", "Quel temps à Paris ?"},
               {"assistant", "Il fait 21 degrés à Paris."}
             ] = persisted(conversation_id)
    end

    test "TOOL-9: a caller tool may not take the name of a ZAQ tool" do
      shadow = put_in(@weather, ["function", "name"], "search_knowledge_base")

      assert %{"error" => %{"message" => _}} =
               json_response(chat(request(%{"tools" => [shadow]})), 502)

      assert llm_calls() == []
    end

    test "TOOL-10: the internal tool loop is bounded and never leaks into tool_calls", ctx do
      script(ctx, for(i <- 1..11, do: call_tools([search("k#{i}", "boucle")])))

      resp = json_response(chat(request(%{"tools" => [@weather]})), 502)

      assert %{"error" => %{"message" => _}} = resp
      assert length(llm_calls()) == 10
    end
  end

  # ---------------------------------------------------------------------------
  # Rules that hold for runs with and without caller tools.
  # ---------------------------------------------------------------------------

  for {label, extra} <- [
        {"with caller tools", %{"tools" => [@weather]}},
        {"without caller tools", %{}}
      ] do
    describe "failed runs and cancellation, #{label}" do
      @describetag extra: extra

      test "USAGE-4: a failed run still reports the usage of its model calls", ctx do
        script(ctx, [
          call_tools([search("k1", "budget")],
            usage: %{"prompt_tokens" => 100, "completion_tokens" => 10, "total_tokens" => 110}
          ),
          provider_error(500),
          provider_error(500),
          provider_error(500)
        ])

        assert %{
                 "error" => %{"message" => _},
                 "usage" => %{
                   "prompt_tokens" => 100,
                   "completion_tokens" => 10,
                   "total_tokens" => 110
                 }
               } = json_response(chat(request(ctx.extra)), 502)
      end

      test "USAGE-4: when streaming, the usage chunk follows the in-band error chunk", ctx do
        script(ctx, [
          call_tools([search("k1", "budget")],
            usage: %{"prompt_tokens" => 100, "completion_tokens" => 10, "total_tokens" => 110}
          ),
          provider_error(500),
          provider_error(500),
          provider_error(500)
        ])

        sse =
          ctx.extra
          |> Map.put("stream_options", %{"include_usage" => true})
          |> stream()
          |> response(200)

        assert [error_chunk, usage_chunk] = sse |> data_frames() |> Enum.take(-2)
        assert %{"error" => %{"type" => "server_error"}} = error_chunk

        assert %{
                 "choices" => [],
                 "usage" => %{
                   "prompt_tokens" => 100,
                   "completion_tokens" => 10,
                   "total_tokens" => 110
                 }
               } = usage_chunk

        assert String.ends_with?(sse, "data: [DONE]\n\n")
      end

      test "TOOL-11: a call to an unknown tool is answered with an error and the turn continues",
           ctx do
        # A run that crashes would only surface as the idle timeout.
        with_timing(chat_result_timeout_ms: 5_000)

        script(ctx, [
          call_tools([{"u1", "lire_fichier", %{"chemin" => "/etc/passwd"}}]),
          answer("Je ne peux pas lire ce fichier.")
        ])

        resp = json_response(chat(request(ctx.extra)), 200)

        assert [%{"finish_reason" => "stop", "message" => %{"content" => content}}] =
                 resp["choices"]

        assert content == "Je ne peux pas lire ce fichier."
        assert [_call, continuation] = llm_calls()

        assert %{"role" => "tool", "tool_call_id" => "u1", "content" => result} =
                 List.last(continuation["messages"])

        assert result =~ "lire_fichier"
        assert result =~ "not found"
      end

      test "CANCEL-1/CANCEL-2/CANCEL-3: a client that disconnects cancels the run, which stores nothing",
           ctx do
        parts = for i <- 1..30, do: "Étape #{i} de la recherche en cours. "

        script(ctx, [
          call_tools([search("k1", "budget")], text: parts, pause_ms: 100),
          answer("Jamais envoyé.")
        ])

        conversation_id = Ecto.UUID.generate()

        received =
          ctx.extra
          |> Map.put("conversation_id", conversation_id)
          |> request()
          |> disconnect_after_content()

        assert received =~ "Étape 1"
        assert_receive {:llm_call, _first}, 1_000

        # The model call in progress is abandoned: its connection is closed
        # long before its 3 s of output are written.
        assert_receive :llm_stream_closed, 2_500
        refute_receive {:llm_call, _}, 1_000
        assert persisted(conversation_id) == []
      end

      test "CANCEL-2/CANCEL-3: a request that times out cancels its run, which stores nothing",
           ctx do
        with_timing(chat_result_timeout_ms: 1_000)

        # A model call that reasons for 4 s without producing content.
        script(ctx, [
          call_tools([search("k1", "budget")],
            reasoning: List.duplicate("Je réfléchis. ", 40),
            pause_ms: 100
          ),
          answer("Trop tard.")
        ])

        conversation_id = Ecto.UUID.generate()
        body = request(Map.put(ctx.extra, "conversation_id", conversation_id))

        assert json_response(chat(body), 502)
        assert_receive {:llm_call, _first}, 1_000
        assert_receive :llm_stream_closed, 2_500
        refute_receive {:llm_call, _}, 1_000
        assert persisted(conversation_id) == []
      end
    end
  end

  describe "cancellation with caller tools" do
    test "CANCEL-3: the caller can ask again; the abandoned turn is not in the history", ctx do
      parts = for i <- 1..30, do: "Étape #{i} de la recherche en cours. "
      script(ctx, [answer(parts, pause_ms: 100)])
      base = %{"conversation_id" => Ecto.UUID.generate(), "tools" => [@weather]}

      base
      |> Map.put("messages", [user("Question abandonnée")])
      |> request()
      |> disconnect_after_content()

      assert_receive :llm_stream_closed, 2_500

      script(ctx, [answer("Nouvelle réponse.")])
      follow_up = request(Map.put(base, "messages", [user("Nouvelle question")]))
      assert json_response(chat(follow_up), 200)
      assert [_abandoned, call] = llm_calls()
      refute model_input(call) =~ "Question abandonnée"
      refute model_input(call) =~ "Étape"
    end
  end

  describe "caller-tool run parity" do
    test "TOOL-12: a tool exchange beyond the context window fails without calling the model",
         ctx do
      script(ctx, [answer("Jamais.")])

      call = %{
        "id" => "call_1",
        "type" => "function",
        "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Paris"})}
      }

      body =
        request(%{
          "tools" => [@weather],
          "messages" => [
            user("Quel temps à Paris ?"),
            %{"role" => "assistant", "content" => nil, "tool_calls" => [call]},
            %{
              "role" => "tool",
              "tool_call_id" => "call_1",
              "content" => String.duplicate("nuage ", 60_000)
            }
          ]
        })

      assert %{"error" => %{"message" => _}} = json_response(chat(body), 502)
      assert llm_calls() == []
    end

    test "TOOL-12: stored history is dropped oldest turn first to fit the context window", ctx do
      # Each stored answer takes a little over half of the 128k-token window.
      long = &(&1 <> " " <> String.duplicate("compte rendu ", 11_000))
      script(ctx, [answer(long.("PREMIER")), answer(long.("SECOND")), answer("Réponse.")])
      base = %{"conversation_id" => Ecto.UUID.generate()}

      for question <- ["Un", "Deux"] do
        assert json_response(chat(request(Map.put(base, "messages", [user(question)]))), 200)
      end

      with_tools = Map.merge(base, %{"tools" => [@weather], "messages" => [user("Trois")]})
      assert json_response(chat(request(with_tools)), 200)

      assert [_first, _second, third] = llm_calls()
      refute model_input(third) =~ "PREMIER"
      assert model_input(third) =~ "SECOND"
      assert last_user_text(third) =~ "Trois"
    end

    test "TOOL-13: runs with caller tools record the same telemetry as runs without", ctx do
      Sandbox.allow(Repo, self(), Process.whereis(Buffer))
      script(ctx, [answer("Sans outils."), answer("Avec outils.")])

      without = recorded_metrics(fn -> json_response(chat(request()), 200) end)

      with_tools =
        recorded_metrics(fn -> json_response(chat(request(%{"tools" => [@weather]})), 200) end)

      assert Enum.any?(without, &match?({"qa.llm.call.count", _dimensions}, &1))
      assert with_tools == without
    end
  end

  defp split("", _sizes), do: []

  defp split(text, [size | sizes]) do
    {part, rest} = String.split_at(text, size)
    [part | split(rest, sizes ++ [size])]
  end
end
