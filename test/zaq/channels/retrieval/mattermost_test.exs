defmodule Zaq.Channels.Retrieval.MattermostTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.ChannelConfig
  alias Zaq.Channels.PendingQuestions
  alias Zaq.Channels.Retrieval.Mattermost
  alias Zaq.Channels.RetrievalChannel
  alias Zaq.Repo

  setup do
    Application.put_env(:zaq, :mattermost_api_module, __MODULE__.APIStub)
    Application.put_env(:zaq, :mattermost_node_router_module, __MODULE__.NodeRouterStub)
    Application.put_env(:zaq, :mattermost_prompt_guard_module, __MODULE__.PromptGuardStub)
    Application.put_env(:zaq, :mattermost_prompt_template_module, __MODULE__.PromptTemplateStub)
    Application.put_env(:zaq, :mattermost_answering_module, __MODULE__.AnsweringStub)
    Application.put_env(:zaq, :mattermost_retrieval_module, __MODULE__.RetrievalStub)

    Application.put_env(
      :zaq,
      :mattermost_document_processor_module,
      __MODULE__.DocumentProcessorStub
    )

    Application.put_env(:zaq, :mattermost_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:zaq, :mattermost_api_module)
      Application.delete_env(:zaq, :mattermost_node_router_module)
      Application.delete_env(:zaq, :mattermost_prompt_guard_module)
      Application.delete_env(:zaq, :mattermost_prompt_template_module)
      Application.delete_env(:zaq, :mattermost_answering_module)
      Application.delete_env(:zaq, :mattermost_retrieval_module)
      Application.delete_env(:zaq, :mattermost_document_processor_module)
      Application.delete_env(:zaq, :mattermost_test_pid)
    end)

    case Process.whereis(PendingQuestions) do
      nil -> start_supervised!({PendingQuestions, []})
      _pid -> :ok
    end

    Agent.update(PendingQuestions, fn _state -> %{} end)
    :ok
  end

  test "handle_in/2 ignores invalid JSON payloads" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    assert {:ok, ^state} = Mattermost.handle_in({:text, "not-json"}, state)
  end

  test "handle_in/2 ignores websocket payloads without event field" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}
    payload = Jason.encode!(%{"seq_reply" => 1})

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
  end

  test "handle_connect/3 returns state unchanged" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}
    assert {:ok, ^state} = Mattermost.handle_connect(101, [], state)
  end

  test "handle_disconnect/3 asks Fresh to reconnect" do
    assert :reconnect = Mattermost.handle_disconnect(1006, "lost", %{})
  end

  test "connect/1 starts channel process and disconnect/1 closes it" do
    config = insert_mattermost_config(url: "http://127.0.0.1:1")

    assert {:ok, pid} = Mattermost.connect(config)
    assert is_pid(pid)
    assert :ok = Mattermost.disconnect(pid)
  end

  test "reload_channels/0 is safe even without process" do
    assert :ok = Mattermost.reload_channels()
  end

  test "send_message/3 delegates to API module" do
    assert {:ok, %{"id" => "stub-post"}} =
             Mattermost.send_message("channel-1", "hello", "thread-1")

    assert_receive {:api_send_message, "channel-1", "hello", "thread-1"}
  end

  test "handle_event/1 is a no-op" do
    assert :ok = Mattermost.handle_event(%{kind: :noop})
  end

  test "handle_info/2 ignores unrelated messages" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}
    assert {:ok, ^state} = Mattermost.handle_info(:noop, state)
  end

  test "handle_in/2 logs and ignores non-posted events" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}
    payload = Jason.encode!(%{"event" => "typing", "data" => %{}})

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
  end

  test "handle_in/2 ignores posted events missing @zaq mention" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      posted_payload(%{
        id: "post-1",
        channel_id: "channel-1",
        message: "where docs?",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
    refute_receive {:api_send_message, _, _, _}
  end

  test "handle_in/2 forwards posted event happy path from websocket payload" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      posted_payload(%{
        id: "post-happy-1",
        channel_id: "channel-1",
        message: "@zaq where are the runbooks?",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
    assert_receive {:api_send_typing, "channel-1", "post-happy-1"}
    assert_receive {:api_send_message, "channel-1", "all good", "post-happy-1"}
  end

  test "handle_in/2 treats empty root_id as non-pending and forwards" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      posted_payload(%{
        id: "post-root-empty-1",
        channel_id: "channel-1",
        root_id: "",
        message: "@zaq answer this please",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
    assert_receive {:api_send_typing, "channel-1", ""}
    assert_receive {:api_send_message, "channel-1", "all good", ""}
  end

  test "handle_in/2 uses mention boundary and case-insensitive matching" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1", "channel-2"])}

    no_trigger_payload =
      posted_payload(%{
        id: "post-boundary-1",
        channel_id: "channel-1",
        message: "@zaqbot do you listen?",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, no_trigger_payload}, state)
    refute_receive {:api_send_typing, "channel-1", _}
    refute_receive {:api_send_message, "channel-1", _, _}

    trigger_payload =
      posted_payload(%{
        id: "post-case-1",
        channel_id: "channel-2",
        message: "@ZAQ give me status",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, trigger_payload}, state)
    assert_receive {:api_send_typing, "channel-2", "post-case-1"}
    assert_receive {:api_send_message, "channel-2", "all good", "post-case-1"}
  end

  test "handle_in/2 ignores malformed posted events" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      Jason.encode!(%{
        "event" => "posted",
        "data" => %{
          "post" => "{not-json",
          "sender_name" => "alice",
          "channel_type" => "O",
          "channel_name" => "engineering"
        }
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
  end

  test "handle_in/2 returns {:ok, state} for posted event with unknown shape" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      Jason.encode!(%{
        "event" => "posted",
        "datax" => %{"post" => Jason.encode!(%{"id" => "post-1"})}
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
    refute_receive {:api_send_typing, _, _}
    refute_receive {:api_send_message, _, _, _}
  end

  test "handle_in/2 ignores posted events sent by @zaq" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      posted_payload(%{
        id: "post-1",
        channel_id: "channel-1",
        message: "@zaq hi",
        sender_name: "@zaq"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
  end

  test "handle_in/2 ignores posts from unmonitored channels" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      posted_payload(%{
        id: "post-1",
        channel_id: "channel-2",
        message: "@zaq where docs?",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
  end

  test "handle_in/2 resolves pending thread replies through PendingQuestions" do
    test_pid = self()

    on_answer = fn answer -> send(test_pid, {:answered, answer}) end

    send_fn = fn _channel_id, _question ->
      {:ok, %{"id" => "root-post-1", "user_id" => "bot-user-1"}}
    end

    assert {:ok, "root-post-1"} =
             PendingQuestions.ask("channel-1", "bot-user-1", "question", send_fn, on_answer)

    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      posted_payload(%{
        id: "reply-post-1",
        channel_id: "channel-1",
        user_id: "human-user-1",
        root_id: "root-post-1",
        message: "Answer from human",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
    assert_receive {:answered, "Answer from human"}
    assert PendingQuestions.pending() == %{}
  end

  test "forward_to_engine/1 sends cleaned successful answer in thread" do
    question = %{
      text: "ok_html",
      channel_id: "channel-1",
      thread_id: nil,
      metadata: %{post_id: "post-1", sender_name: "alice"}
    }

    assert :ok = Mattermost.forward_to_engine(question)
    assert_receive {:api_send_typing, "channel-1", "post-1"}
    assert_receive {:api_send_message, "channel-1", "ok <tag>", "post-1"}
  end

  test "forward_to_engine/1 handles safety and retrieval error branches" do
    cases = [
      {"inject", "I can only help with ZAQ-related questions."},
      {"roleplay", "I can only help with ZAQ-related questions."},
      {"unsafe", "I can only help with ZAQ-related questions."},
      {"blocked", "Sorry, something went wrong. Please try again."},
      {"query_empty", "none"},
      {"no_results_neg", "No docs found."},
      {"no_results_plain", "I couldn't find relevant information to answer your question."},
      {"query_empty_results", "No docs found from empty results."},
      {"answering_error", "Sorry, something went wrong. Please try again."},
      {"query_error", "No docs found from extraction."},
      {"plain_answer", "simple answer"},
      {"retrieval_error", "Sorry, something went wrong. Please try again."}
    ]

    for {text, expected_reply} <- cases do
      channel_id = "channel-" <> text
      thread_id = "thread-" <> text

      question = %{
        text: text,
        channel_id: channel_id,
        thread_id: thread_id,
        metadata: %{post_id: "post-#{text}", sender_name: "alice"}
      }

      assert :ok = Mattermost.forward_to_engine(question)
      assert_receive {:api_send_typing, ^channel_id, ^thread_id}
      assert_receive {:api_send_message, ^channel_id, ^expected_reply, ^thread_id}
    end
  end

  test "forward_to_engine/1 handles no-answer and send_message errors" do
    question = %{
      text: "no_answer",
      channel_id: "send-error",
      thread_id: "thread-1",
      metadata: %{post_id: "post-1", sender_name: "alice"}
    }

    assert :ok = Mattermost.forward_to_engine(question)
    assert_receive {:api_send_typing, "send-error", "thread-1"}
    assert_receive {:api_send_message, "send-error", "No answer available", "thread-1"}
  end

  test "forward_to_engine/1 expands clean_body entity and formatting cleanup" do
    question = %{
      text: "cleanup_mix",
      channel_id: "channel-cleanup",
      thread_id: "thread-cleanup",
      metadata: %{post_id: "post-cleanup", sender_name: "alice"}
    }

    assert :ok = Mattermost.forward_to_engine(question)
    assert_receive {:api_send_typing, "channel-cleanup", "thread-cleanup"}

    assert_receive {:api_send_message, "channel-cleanup", cleaned, "thread-cleanup"}
    assert cleaned == "A & B <C> \"D\" 'E'\n\nClick\nNext line"
  end

  test "connect/1 builds wss websocket uri for https urls" do
    config = insert_mattermost_config(url: "https://127.0.0.1:1")

    assert {:ok, pid} = Mattermost.connect(config)
    assert is_pid(pid)
    assert :ok = Mattermost.disconnect(pid)
  end

  test "handle_info/2 reloads monitored channels from database" do
    config = insert_mattermost_config()
    insert_retrieval_channel(config.id, "channel-a", active: true)
    insert_retrieval_channel(config.id, "channel-b", active: false)

    state = %{monitored_channel_ids: MapSet.new()}

    assert {:ok, new_state} = Mattermost.handle_info(:reload_channels, state)
    assert MapSet.member?(new_state.monitored_channel_ids, "channel-a")
    refute MapSet.member?(new_state.monitored_channel_ids, "channel-b")
  end

  test "handle_in/2 ignores pending replies with no matching question" do
    state = %{monitored_channel_ids: MapSet.new(["channel-1"])}

    payload =
      posted_payload(%{
        id: "reply-post-2",
        channel_id: "channel-1",
        user_id: "human-user-2",
        root_id: "unknown-root",
        message: "@zaq answer",
        sender_name: "alice"
      })

    assert {:ok, ^state} = Mattermost.handle_in({:text, payload}, state)
    refute_receive {:api_send_message, _, _, _}
  end

  defp posted_payload(attrs) do
    post = %{
      "id" => attrs.id,
      "message" => attrs.message,
      "user_id" => Map.get(attrs, :user_id, "user-1"),
      "channel_id" => attrs.channel_id,
      "root_id" => Map.get(attrs, :root_id),
      "create_at" => 1_710_000_001
    }

    Jason.encode!(%{
      "event" => "posted",
      "data" => %{
        "post" => Jason.encode!(post),
        "sender_name" => attrs.sender_name,
        "channel_type" => "O",
        "channel_name" => "engineering"
      }
    })
  end

  defp insert_mattermost_config(attrs \\ []) do
    defaults = %{
      name: "Mattermost",
      provider: "mattermost",
      kind: "retrieval",
      url: "https://mattermost.example.com",
      token: "test-token",
      enabled: true
    }

    %ChannelConfig{}
    |> ChannelConfig.changeset(Enum.into(attrs, defaults))
    |> Repo.insert!()
  end

  defp insert_retrieval_channel(config_id, channel_id, attrs) do
    defaults = %{
      channel_config_id: config_id,
      channel_id: channel_id,
      channel_name: channel_id,
      team_id: "team-1",
      team_name: "Team",
      active: true
    }

    %RetrievalChannel{}
    |> RetrievalChannel.changeset(Enum.into(attrs, defaults))
    |> Repo.insert!()
  end

  defmodule APIStub do
    def send_typing(channel_id, thread_id) do
      send(test_pid(), {:api_send_typing, channel_id, thread_id})
      :ok
    end

    def send_message(channel_id, message, thread_id) do
      send(test_pid(), {:api_send_message, channel_id, message, thread_id})

      if channel_id == "send-error" do
        {:error, :send_failed}
      else
        {:ok, %{"id" => "stub-post"}}
      end
    end

    defp test_pid do
      Application.fetch_env!(:zaq, :mattermost_test_pid)
    end
  end

  defmodule PromptGuardStub do
    def validate("inject"), do: {:error, :prompt_injection}
    def validate("roleplay"), do: {:error, :role_play_attempt}
    def validate(text), do: {:ok, "clean:" <> text}

    def output_safe?("unsafe"), do: {:error, {:leaked, "unsafe output"}}
    def output_safe?(text), do: {:ok, text}
  end

  defmodule PromptTemplateStub do
    def render("answering", %{question: question}), do: "prompt:" <> question
  end

  defmodule NodeRouterStub do
    @retrieval_overrides %{
      "clean:no_results_neg" => {:ok, %{"negative_answer" => "No docs found."}},
      "clean:no_results_plain" => {:ok, %{}},
      "clean:retrieval_error" => {:error, :retrieval_failed},
      "clean:blocked" => {:ok, %{"error" => "blocked"}},
      "clean:query_error" =>
        {:ok,
         %{
           "query" => "query-error",
           "language" => "en",
           "positive_answer" => "yes",
           "negative_answer" => "No docs found from extraction."
         }},
      "clean:query_empty_results" =>
        {:ok,
         %{
           "query" => "query-empty-results",
           "language" => "en",
           "positive_answer" => "yes",
           "negative_answer" => "No docs found from empty results."
         }},
      "clean:answering_error" =>
        {:ok,
         %{
           "query" => "answering-error",
           "language" => "en",
           "positive_answer" => "yes",
           "negative_answer" => "none"
         }},
      "clean:query_empty" =>
        {:ok,
         %{
           "query" => "",
           "language" => "en",
           "positive_answer" => "yes",
           "negative_answer" => "none"
         }}
    }

    def call(:agent, retrieval_mod, :ask, [clean_msg, [history: %{}]])
        when retrieval_mod == Zaq.Channels.Retrieval.MattermostTest.RetrievalStub do
      Map.get(@retrieval_overrides, clean_msg, default_retrieval_response(clean_msg))
    end

    def call(:ingestion, document_processor_mod, :query_extraction, [query, _role_ids])
        when document_processor_mod == Zaq.Channels.Retrieval.MattermostTest.DocumentProcessorStub do
      if query == "query-error" do
        {:error, :boom}
      else
        if query == "query-empty-results" do
          {:ok, []}
        else
          {:ok, [%{"content" => "ctx:" <> query, "source" => "kb"}]}
        end
      end
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:answering_error"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:error, :answering_failed}
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:query_empty_results"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok, %{answer: "unreachable", confidence: %{score: 0.0}}}
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:query_empty"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok, %{answer: "unreachable", confidence: %{score: 0.0}}}
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:ok_html"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok,
       %{answer: "<b>ok</b> <a href='x'>&lt;tag&gt;</a> [source: kb]", confidence: %{score: 0.91}}}
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:no_answer"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok, %{answer: "NO_ANSWER: No answer available", confidence: %{score: 0.1}}}
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:cleanup_mix"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok,
       %{
         answer:
           "<b>A &amp; B</b> <a href='x'>&lt;C&gt;</a> &quot;D&quot; &#39;E&#39;\n\n\n<a href='y'>Click</a>\nNext line [source: kb]",
         confidence: %{score: 0.95}
       }}
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:unsafe"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok, %{answer: "unsafe", confidence: %{score: 0.2}}}
    end

    def call(:agent, answering_mod, :ask, ["prompt:clean:plain_answer"])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok, "simple answer"}
    end

    def call(:agent, answering_mod, :ask, [_prompt])
        when answering_mod == Zaq.Channels.Retrieval.MattermostTest.AnsweringStub do
      {:ok, %{answer: "all good", confidence: %{score: 0.8}}}
    end

    defp default_retrieval_response(clean_msg) do
      {:ok,
       %{
         "query" => "query:" <> clean_msg,
         "language" => "en",
         "positive_answer" => "yes",
         "negative_answer" => "none"
       }}
    end
  end

  defmodule RetrievalStub do
  end

  defmodule DocumentProcessorStub do
  end

  defmodule AnsweringStub do
    def no_answer?("NO_ANSWER: " <> _), do: true
    def no_answer?(_), do: false

    def clean_answer("NO_ANSWER: " <> rest), do: rest
    def clean_answer(answer), do: answer
  end
end
