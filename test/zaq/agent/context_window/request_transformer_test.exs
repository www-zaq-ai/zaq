defmodule Zaq.Agent.ContextWindow.RequestTransformerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.AI.Context, as: AIContext
  alias Jido.AI.Context.Entry
  alias Jido.AI.Reasoning.ReAct.Config
  alias ReqLLM.Message.ContentPart
  alias Zaq.Agent.ContextWindow.RequestEstimator
  alias Zaq.Agent.ContextWindow.RequestTransformer

  test "steering cannot make the original task and its tool exchange evictable" do
    context =
      AIContext.new()
      |> AIContext.append_user("Original task", refs: %{execution_root: "root"})
      |> AIContext.append(%Entry{
        role: :assistant,
        content: "",
        tool_calls: [%{id: "active-call", name: "lookup", arguments: %{}}]
      })
      |> AIContext.append(%Entry{
        role: :tool,
        content: String.duplicate("large active result ", 1_000),
        tool_call_id: "active-call"
      })
      |> AIContext.append_user("Use the second option")

    assert {:error, {:context_window_exceeded, :mandatory_payload_too_large}} =
             RequestTransformer.transform_request(
               %{messages: AIContext.to_messages(context)},
               %{context: context},
               config(1),
               %{context_window: window(100), execution_root: "root"}
             )
  end

  property "budgeting preserves every active correction in order and evicts only background" do
    check all(
            corrections <-
              list_of(string(:alphanumeric, min_length: 1, max_length: 40),
                min_length: 1,
                max_length: 6
              )
          ) do
      active =
        Enum.reduce(
          corrections,
          AIContext.new()
          |> AIContext.append_user("Root", refs: %{execution_root: "root"}),
          &AIContext.append_user(&2, &1)
        )

      context = %{
        active
        | entries:
            active.entries ++ [%Entry{role: :user, content: String.duplicate("old", 2_000)}]
      }

      expected = AIContext.to_messages(active)
      budget = RequestEstimator.estimate(%{messages: expected}, window(1))

      assert {:ok, %{messages: ^expected}} =
               RequestTransformer.transform_request(
                 %{messages: AIContext.to_messages(context)},
                 %{context: context},
                 config(1),
                 %{context_window: window(budget + 1), execution_root: "root"}
               )
    end
  end

  defp config(max_tokens \\ 10, output \\ nil),
    do: struct(Config, llm: %{max_tokens: max_tokens}, output: output)

  defp window(tokens) do
    %{max_context_tokens: tokens, tokens_per_character: 0.1, safety_margin: 0.0}
  end

  test "leaves a request unchanged when it fits the input budget" do
    request = %{
      messages: [%{role: "user", content: "short question"}],
      llm_opts: [],
      tools: [],
      model: :test
    }

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(), %{
               context_window: window(1_000)
             })

    assert messages == request.messages
  end

  test "preserves binary skill resources within budget and rejects oversized mandatory resources" do
    part =
      ContentPart.file("%PDF-1.3\n%" <> <<255, 255, 255, 255>>, "guide.pdf", "application/pdf")

    request = %{
      messages: [
        %ReqLLM.Message{role: :user, content: [ContentPart.text("Read the skill resource")]},
        %ReqLLM.Message{role: :user, content: [part]}
      ]
    }

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(1_000)
             })

    assert messages == request.messages

    assert {:error, {:context_window_exceeded, :mandatory_payload_too_large}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(2)
             })
  end

  test "drops oldest historical units before the current user turn" do
    request = %{
      messages: [
        %{role: "user", content: String.duplicate("old user ", 120)},
        %{role: "assistant", content: String.duplicate("old assistant ", 120)},
        %{role: "user", content: "current question"}
      ],
      llm_opts: [],
      tools: [],
      model: :test
    }

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(40)
             })

    assert messages == [%{role: "user", content: "current question"}]
  end

  test "keeps assistant tool calls with their tool results as one evictable unit" do
    tool_call = %{id: "call_1", name: "lookup", arguments: %{}}

    request = %{
      messages: [
        %{role: "assistant", content: nil, tool_calls: [tool_call]},
        %{role: "tool", content: String.duplicate("tool output ", 100), tool_call_id: "call_1"},
        %{role: "user", content: "current question"}
      ],
      llm_opts: [],
      tools: [],
      model: :test
    }

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(40)
             })

    refute Enum.any?(messages, &(Map.get(&1, :role) == "tool"))
    assert List.last(messages).content == "current question"
  end

  test "drops old tool interactions before newer text history" do
    tool_call = %{id: "call_1", name: "lookup", arguments: %{}}

    old_tool_call = %{role: "assistant", content: nil, tool_calls: [tool_call]}

    old_tool_result = %{
      role: "tool",
      content: String.duplicate("tool output ", 100),
      tool_call_id: "call_1"
    }

    recent_assistant = %{role: "assistant", content: "recent assistant answer"}
    current_user = %{role: "user", content: "current question"}
    system = %{role: :system, content: "System instructions"}
    tool_system = %{role: "system", content: "Instructions between tool call and result"}
    later_system = %{role: "system", content: "Additional instructions"}

    request = %{
      messages: [
        system,
        old_tool_call,
        tool_system,
        old_tool_result,
        recent_assistant,
        later_system,
        current_user
      ],
      llm_opts: [],
      tools: [],
      model: :test
    }

    desired_messages = [system, tool_system, recent_assistant, later_system, current_user]

    desired_budget =
      RequestEstimator.estimate(%{request | messages: desired_messages}, window(1))

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(desired_budget + 1)
             })

    assert messages == desired_messages
  end

  test "returns an explicit error when mandatory content cannot fit" do
    request = %{
      messages: [%{role: "user", content: String.duplicate("current ", 1_000)}],
      llm_opts: [],
      tools: [],
      model: :test
    }

    assert {:error, {:context_window_exceeded, :mandatory_payload_too_large}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(20)
             })
  end

  test "rejects requests whose messages are not a list" do
    for messages <- [nil, %{}] do
      request = %{messages: messages, llm_opts: [], tools: [], model: :test}

      assert {:error, {:context_window_exceeded, :invalid_messages}} =
               RequestTransformer.transform_request(request, nil, config(), %{
                 context_window: window(1_000)
               })
    end
  end

  test "treats a struct assistant message with empty tool calls as a standalone unit" do
    assistant = %Entry{
      role: :assistant,
      content: String.duplicate("old assistant ", 120),
      tool_calls: []
    }

    tool_result = %{role: "tool", content: "lookup result", tool_call_id: "call_1"}
    current_user = %{role: "user", content: "current question"}

    request = %{
      messages: [assistant, tool_result, current_user],
      llm_opts: [],
      tools: [],
      model: :test
    }

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(40)
             })

    assert messages == [tool_result, current_user]
  end

  test "handles malformed scalar history entries as roleless evictable messages" do
    current_user = %{role: "user", content: "current question"}

    request = %{
      messages: [String.duplicate("malformed history ", 120), current_user],
      llm_opts: [],
      tools: [],
      model: :test
    }

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(40)
             })

    assert messages == [current_user]
  end

  test "includes configured output schemas in the request estimate" do
    request = %{messages: [%{role: "user", content: "ok"}], llm_opts: [], tools: [], model: :test}
    output = %{type: "object", description: String.duplicate("schema ", 500)}

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: window(100)
             })

    assert messages == request.messages

    assert {:error, {:context_window_exceeded, :mandatory_payload_too_large}} =
             RequestTransformer.transform_request(request, nil, config(1, output), %{
               context_window: window(100)
             })
  end

  test "rejects non-positive and non-integer context-window sizes" do
    request = %{messages: [%{role: "user", content: "ok"}], llm_opts: [], tools: [], model: :test}

    for max_context_tokens <- [nil, 0, -1, 1.5, "100"] do
      assert {:error, {:context_window_exceeded, :no_input_budget}} =
               RequestTransformer.transform_request(request, nil, config(), %{
                 context_window: window(max_context_tokens)
               })
    end
  end

  test "falls back to the default safety margin for invalid values" do
    request = %{messages: [%{role: "user", content: "ok"}], llm_opts: [], tools: [], model: :test}
    estimate = RequestEstimator.estimate(request, %{tokens_per_character: 0.1})
    max_context_tokens = estimate + 1

    assert {:ok, %{messages: messages}} =
             RequestTransformer.transform_request(request, nil, config(1), %{
               context_window: %{
                 max_context_tokens: max_context_tokens,
                 tokens_per_character: 0.1,
                 safety_margin: 0.0
               }
             })

    assert messages == request.messages

    for safety_margin <- [1.0, -0.1, "0.0"] do
      assert {:error, {:context_window_exceeded, :mandatory_payload_too_large}} =
               RequestTransformer.transform_request(request, nil, config(1), %{
                 context_window: %{
                   max_context_tokens: max_context_tokens,
                   tokens_per_character: 0.1,
                   safety_margin: safety_margin
                 }
               })
    end
  end

  property "projection preserves original order, system messages and the latest user turn" do
    check all(
            prior <- list_of(string(:alphanumeric, min_length: 1, max_length: 12), max_length: 8),
            current <- string(:alphanumeric, min_length: 1, max_length: 12),
            system_role <- member_of([:system, "system"]),
            retained_count <- integer(0..2),
            max_runs: 25
          ) do
      system = %{role: system_role, content: "System"}
      current_user = %{role: "user", content: current}

      units =
        Enum.map(prior ++ prior, fn text ->
          [%{role: "assistant", content: text}, %{role: system_role, content: "Context"}]
        end)

      messages =
        [system] ++ List.flatten(units) ++ [current_user]

      request = %{messages: messages, llm_opts: [], tools: [], model: :test}
      keep_from = max(length(units) - retained_count, 0)

      expected =
        [system] ++
          (units
           |> Enum.with_index()
           |> Enum.flat_map(fn
             {[assistant, context], index} when index >= keep_from -> [assistant, context]
             {[_assistant, context], _index} -> [context]
           end)) ++ [current_user]

      budget = RequestEstimator.estimate(%{request | messages: expected}, window(1))

      assert {:ok, %{messages: projected}} =
               RequestTransformer.transform_request(request, nil, config(1), %{
                 context_window: window(budget + 1)
               })

      assert projected == expected
      assert List.last(projected) == current_user

      assert Enum.filter(projected, &(&1.role == system_role)) ==
               Enum.filter(messages, &(&1.role == system_role))

      assert RequestEstimator.estimate(%{request | messages: projected}, window(1)) <= budget
    end
  end
end
