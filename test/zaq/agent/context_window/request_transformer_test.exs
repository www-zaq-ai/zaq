defmodule Zaq.Agent.ContextWindow.RequestTransformerTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Jido.AI.Context.Entry
  alias Jido.AI.Reasoning.ReAct.Config
  alias Zaq.Agent.ContextWindow.RequestEstimator
  alias Zaq.Agent.ContextWindow.RequestTransformer

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

  property "projected messages preserve order and keep the latest user turn" do
    check all(
            prior <- list_of(string(:alphanumeric, min_length: 1, max_length: 12), max_length: 8),
            current <- string(:alphanumeric, min_length: 1, max_length: 12),
            max_runs: 25
          ) do
      messages =
        Enum.map(prior, &%{role: "assistant", content: &1}) ++
          [%{role: "user", content: current}]

      request = %{messages: messages, llm_opts: [], tools: [], model: :test}

      assert {:ok, %{messages: projected}} =
               RequestTransformer.transform_request(request, nil, config(1), %{
                 context_window: window(200)
               })

      assert List.last(projected) == %{role: "user", content: current}
      assert projected == Enum.filter(messages, &(&1 in projected))
      assert RequestEstimator.estimate(%{request | messages: projected}, window(200)) <= 199
    end
  end
end
