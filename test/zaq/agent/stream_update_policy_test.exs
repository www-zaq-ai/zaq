defmodule Zaq.Agent.StreamUpdatePolicyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Agent.StreamEvents
  alias Zaq.ConnectorConfig.LiveUpdates
  alias Zaq.Engine.Messages.Incoming

  defmodule Status do
    def broadcast(incoming, stage, text, _router, opts) do
      send(self(), {:update, stage, text, opts})
      put_in(incoming.metadata[:status_message_id], "published")
    end
  end

  test "all three managed event types share the reducer interval" do
    events = [
      delta(99, :content, String.duplicate("a", 21)),
      tool(100, "one"),
      delta(199, :content, "b"),
      delta(200, :thinking, String.duplicate("r", 21)),
      tool(299, "two"),
      tool(300, "three"),
      done(301)
    ]

    assert {:ok, result} = consume(events)
    assert_receive {:update, :tool_call, _, _}
    assert_receive {:update, :thinking, _, _}
    assert_receive {:update, :tool_call, _, _}
    refute_receive {:update, _, _, _}
    assert length(result.tool_calls) == 3
  end

  test "disabled tool trigger does not consume a slot or filter the next text snapshot" do
    policy = %{"triggers" => %{"tool_call" => false}}

    assert {:ok, _result} =
             consume(
               [tool(100, "one"), delta(100, :content, String.duplicate("a", 21)), done(101)],
               live_update_policy: policy
             )

    assert_receive {:update, :answering, _, opts}
    assert [%{"id" => "one", "state" => "running"}] = opts[:tool_steps]
    refute_receive {:update, _, _, _}
  end

  test "master off suppresses managed updates but not lifecycle status or evidence" do
    events = [
      event(:request_started, 0),
      tool(100, "one"),
      delta(200, :content, "answer"),
      done(300)
    ]

    assert {:ok, result} =
             consume(events,
               live_update_policy: %{"enabled" => false},
               notify_execution_lifecycle: true
             )

    assert_receive {:update, :execution_started, "Preparing answer", _}
    refute_receive {:update, _, _, _}
    assert result.answer == "answer"
    assert [%{"outcome" => "unknown"}] = result.tool_calls
    refute result.answer_published?
  end

  test "status does not consume the managed interval" do
    assert {:ok, _result} =
             consume([event(:request_started, 99), tool(100, "one"), done(101)],
               notify_execution_lifecycle: true
             )

    assert_receive {:update, :execution_started, _, _}
    assert_receive {:update, :tool_call, _, _}
    refute_receive {:update, _, _, _}
  end

  test "time limiting off still retains the internal text byte threshold" do
    assert {:ok, result} =
             consume(
               [
                 delta(0, :content, String.duplicate("a", 20)),
                 delta(0, :content, "é"),
                 tool(0, "one"),
                 done(0)
               ],
               live_update_policy: %{"throttle_enabled" => false}
             )

    assert_receive {:update, :answering, text, _}
    assert byte_size(text) == 22
    assert_receive {:update, :tool_call, _, _}
    refute_receive {:update, _, _, _}
    assert result.answer_published?
  end

  test "segment switches, termination and exhaustion never force an intermediate update" do
    for tail <- [[done(500)], []] do
      assert {:ok, result} =
               consume([delta(1, :thinking, "reason"), delta(2, :content, "short")] ++ tail)

      refute_receive {:update, _, _, _}
      refute result.answer_published?
      assert Enum.any?(result.trace, &(&1["content"] == "reason"))
      assert Enum.any?(result.trace, &(&1["type"] == "content"))
      assert result.answer == "short"
    end
  end

  test "invalid supplied policy cannot enable managed updates" do
    for policy <- [nil, %{"triggers" => %{"status" => true}}] do
      assert {:ok, result} = consume([tool(100, "one"), done(200)], live_update_policy: policy)
      refute_receive {:update, _, _, _}
      assert length(result.tool_calls) == 1
    end
  end

  test "a failed stream retains its unpublished answer tail without a terminal publication" do
    prefix = "Here is the beginning of the answer."
    answer = prefix <> " This is the remaining answer text."

    assert {:error, :provider_failure, result} =
             consume([
               delta(100, :content, prefix),
               delta(110, :content, " This is the remaining answer text."),
               event(:request_failed, 120, %{error: :provider_failure})
             ])

    assert_receive {:update, :answering, ^prefix, _}
    refute_receive {:update, _, _, _}
    assert result.answer_published?
    assert result.answer == answer
    assert result.pending_answer == answer
  end

  test "reasoning cannot replace a pending answer after content was published" do
    prefix = "An answer long enough to publish."
    answer = prefix <> " The final detail."

    assert {:error, :provider_failure, result} =
             consume([
               delta(100, :content, prefix),
               delta(110, :content, " The final detail."),
               delta(200, :thinking, "Private reasoning long enough to publish."),
               event(:request_failed, 210, %{error: :provider_failure})
             ])

    assert result.answer == answer
    assert result.pending_answer == answer
    assert result.answer_published?
    assert Enum.any?(result.trace, &(&1["type"] == "reasoning"))
  end

  test "a fully published answer needs no terminal replacement" do
    text = "An answer long enough to publish."
    assert {:ok, result} = consume([delta(100, :content, text), done(110)])
    assert result.answer_published?
    assert result.pending_answer == nil
  end

  property "published whitespace is never evidence of a meaningful answer" do
    check all(
            parts <-
              list_of(member_of([" ", "\t", "\n", "\r", "\u00a0"]),
                min_length: 21,
                max_length: 50
              )
          ) do
      text = Enum.join(parts)

      assert {:error, :provider_failure, result} =
               consume([
                 delta(100, :content, text),
                 event(:request_failed, 110, %{error: :provider_failure})
               ])

      assert_receive {:update, :answering, ^text, _}
      refute result.answer_published?
      assert result.pending_answer == nil
    end
  end

  property "publication preferences never change canonical execution evidence" do
    check all(
            answer <- boolean(),
            reasoning <- boolean(),
            tool <- boolean(),
            interval <- integer(1..500)
          ) do
      events = [
        delta(100, :thinking, String.duplicate("r", 21)),
        tool(200, "one"),
        delta(300, :content, String.duplicate("a", 21)),
        done(400)
      ]

      policy = %{
        "min_interval_ms" => interval,
        "triggers" => %{"stream_delta" => answer, "reasoning" => reasoning, "tool_call" => tool}
      }

      assert {:ok, enabled} = consume(events, live_update_policy: policy)
      assert {:ok, disabled} = consume(events, live_update_policy: %{"enabled" => false})

      fields = [:answer, :usage, :llm_calls, :trace, :trace_artifacts, :tool_calls, :measurements]
      assert Map.take(enabled, fields) == Map.take(disabled, fields)
      drain_updates()
    end
  end

  defp consume(events, opts \\ []) do
    incoming = %Incoming{content: "question", channel_id: "room", provider: :web, metadata: %{}}

    opts =
      Keyword.merge(
        [started_at: 0, status_module: Status, live_update_policy: LiveUpdates.defaults()],
        opts
      )

    StreamEvents.consume(events, incoming, opts)
  end

  defp delta(at, type, text),
    do: event(:llm_delta, at, %{chunk_type: type, delta: text})

  defp tool(at, id),
    do: Map.put(event(:tool_started, at, %{tool_name: "search"}), :tool_call_id, id)

  defp done(at), do: event(:request_completed, at, %{})
  defp event(kind, at, data \\ %{}), do: %{kind: kind, at_ms: at, data: data}

  defp drain_updates do
    receive do
      {:update, _, _, _} -> drain_updates()
    after
      0 -> :ok
    end
  end
end
