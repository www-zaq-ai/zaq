defmodule Zaq.Agent.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.ContextWindow

  # One token per word keeps the arithmetic in these tests obvious.
  @estimator &__MODULE__.word_count/1

  def word_count(text) when is_binary(text) do
    text |> String.split(~r/\s+/, trim: true) |> length()
  end

  defp ctx(entries, opts \\ []) do
    Enum.reduce(entries, AIContext.new(opts), &AIContext.append(&2, &1))
  end

  defp user(content), do: %AIContext.Entry{role: :user, content: content}
  defp assistant(content), do: %AIContext.Entry{role: :assistant, content: content}

  defp assistant_calls(content, ids) do
    %AIContext.Entry{
      role: :assistant,
      content: content,
      tool_calls: Enum.map(ids, &%{id: &1, name: "tool_#{&1}"})
    }
  end

  defp tool_result(id, content, refs \\ nil) do
    %AIContext.Entry{
      role: :tool,
      tool_call_id: id,
      name: "tool_#{id}",
      content: content,
      refs: refs
    }
  end

  defp roles(%AIContext{} = context) do
    context.entries |> Enum.reverse() |> Enum.map(& &1.role)
  end

  defp contents(%AIContext{} = context) do
    context.entries |> Enum.reverse() |> Enum.map(& &1.content)
  end

  defp fit(context, max_tokens) do
    ContextWindow.fit(context, max_tokens: max_tokens, estimator: @estimator)
  end

  describe "fit/2 no-ops" do
    test "returns the context unchanged when no budget is given" do
      context = ctx([user("a b c"), assistant("d e f")])

      assert ContextWindow.fit(context, []) == context
      assert ContextWindow.fit(context, max_tokens: nil) == context
      assert ContextWindow.fit(context, max_tokens: 0) == context
    end

    test "returns the context unchanged when it already fits" do
      context = ctx([user("one"), assistant("two")])

      assert fit(context, 100) == context
    end

    test "handles an empty context" do
      assert fit(ctx([]), 10) |> roles() == []
    end
  end

  describe "fit/2 FIFO eviction" do
    test "drops oldest entries first, keeping the newest" do
      context =
        ctx([
          user("aaa"),
          assistant("bbb"),
          user("ccc"),
          assistant("ddd"),
          user("eee")
        ])

      # Budget of 2 tokens: only the fixed tail (last user) plus one more fits.
      assert contents(fit(context, 2)) == ["ddd", "eee"]
    end

    test "never evicts the last user entry even at a budget of 1" do
      context = ctx([user("aaa"), assistant("bbb"), user("ccc")])

      assert contents(fit(context, 1)) == ["ccc"]
    end

    test "keeps everything after the last user entry as the fixed tail" do
      context =
        ctx([
          user("old"),
          assistant("older reply"),
          user("current"),
          assistant("current reply")
        ])

      assert contents(fit(context, 1)) == ["current", "current reply"]
    end

    test "protects the newest entry when there is no user entry at all" do
      context = ctx([assistant("aaa"), assistant("bbb"), assistant("ccc")])

      assert contents(fit(context, 1)) == ["ccc"]
    end
  end

  describe "fit/2 anchor" do
    # In cold history the most recent :user row is just old history, not a turn
    # in flight — anchoring on it would pin everything after it.
    test ":newest protects only the last group, not the last user turn" do
      context = ctx([user("aaa"), assistant("bbb"), assistant("ccc")])

      newest =
        ContextWindow.fit(context, max_tokens: 1, anchor: :newest, estimator: @estimator)

      turn = ContextWindow.fit(context, max_tokens: 1, anchor: :turn, estimator: @estimator)

      assert contents(newest) == ["ccc"]
      assert contents(turn) == ["aaa", "bbb", "ccc"]
    end

    test ":newest still guarantees a non-empty result" do
      context = ctx([user("aaa"), assistant("one two three four five")])

      fitted =
        ContextWindow.fit(context, max_tokens: 1, anchor: :newest, estimator: @estimator)

      assert contents(fitted) == ["one two three four five"]
    end

    test "defaults to :turn" do
      context = ctx([user("aaa"), assistant("bbb")])

      assert fit(context, 1) ==
               ContextWindow.fit(context, max_tokens: 1, anchor: :turn, estimator: @estimator)
    end
  end

  describe "fit/2 system prompt" do
    test "preserves the system prompt across eviction" do
      context =
        ctx([user("aaa"), assistant("bbb"), user("ccc")], system_prompt: "sys prompt here")

      fitted = fit(context, 2)

      assert fitted.system_prompt == "sys prompt here"
    end

    test "counts the system prompt against the budget" do
      entries = [user("aaa"), assistant("bbb"), user("ccc")]

      without = ctx(entries)
      # 3-token system prompt eats the whole budget of 4, leaving room for the tail only.
      with_prompt = ctx(entries, system_prompt: "one two three")

      assert contents(fit(without, 4)) == ["aaa", "bbb", "ccc"]
      assert contents(fit(with_prompt, 4)) == ["ccc"]
    end
  end

  describe "fit/2 tool-call group integrity" do
    test "evicts an assistant tool_calls stub together with its results" do
      context =
        ctx([
          assistant_calls("calling", ["c1", "c2"]),
          tool_result("c1", "result one"),
          tool_result("c2", "result two"),
          user("newest")
        ])

      fitted = fit(context, 1)

      assert roles(fitted) == [:user]
      assert contents(fitted) == ["newest"]
    end

    test "never leaves an orphan tool result behind" do
      context =
        ctx([
          user("first"),
          assistant_calls("calling", ["c1"]),
          tool_result("c1", "a b c d e f g h"),
          assistant("summary"),
          user("newest")
        ])

      fitted = fit(context, 3)

      refute :tool in roles(fitted)

      refute Enum.any?(
               fitted.entries,
               &(&1.role == :assistant and &1.tool_calls not in [nil, []])
             )
    end

    test "keeps a whole tool group when it fits" do
      context =
        ctx([
          user("old"),
          assistant_calls("calling", ["c1"]),
          tool_result("c1", "res"),
          user("newest")
        ])

      # The group costs its content plus the serialized tool_calls payload.
      assert roles(fit(context, 8)) == [:user, :assistant, :tool, :user]
    end

    test "groups only the tool results belonging to the assistant stub" do
      context =
        ctx([
          assistant_calls("first call", ["c1"]),
          tool_result("c1", "res one"),
          assistant_calls("second call", ["c2"]),
          tool_result("c2", "res two"),
          user("newest")
        ])

      # Budget fits the second group plus the tail, not the first.
      fitted = fit(context, 9)

      assert contents(fitted) == ["second call", "res two", "newest"]
    end
  end

  describe "fit/2 durable pins" do
    test "keeps durable tool results even when older than evicted entries" do
      context =
        ctx([
          assistant_calls("load", ["skill1"]),
          tool_result("skill1", "skill body here", %{durable: true, kind: :skill_activation}),
          user("aaa"),
          assistant("bbb"),
          user("newest")
        ])

      fitted = fit(context, 2)

      assert "skill body here" in contents(fitted)
      assert "newest" in contents(fitted)
      refute "aaa" in contents(fitted)
    end

    test "recognises string-keyed durable refs" do
      context =
        ctx([
          assistant_calls("load", ["skill1"]),
          tool_result("skill1", "skill body", %{"durable" => true}),
          user("aaa"),
          user("newest")
        ])

      assert "skill body" in contents(fit(context, 1))
    end

    test "defaults to :pin" do
      context =
        ctx([
          assistant_calls("load", ["skill1"]),
          tool_result("skill1", "skill body", %{durable: true}),
          user("newest")
        ])

      assert "skill body" in contents(fit(context, 100))
    end

    test "does not pin non-durable tool results" do
      context =
        ctx([
          assistant_calls("call", ["c1"]),
          tool_result("c1", "ordinary result", %{durable: false}),
          user("aaa"),
          user("newest")
        ])

      refute "ordinary result" in contents(fit(context, 1))
    end
  end

  describe "fit_with_stats/2" do
    test "reports eviction counts and token totals" do
      context = ctx([user("aaa"), assistant("bbb"), user("ccc")])

      {_fitted, stats} =
        ContextWindow.fit_with_stats(context, max_tokens: 1, estimator: @estimator)

      assert stats.budget == 1
      assert stats.tokens_before == 3
      assert stats.tokens_after == 1
      assert stats.groups_evicted == 2
      assert stats.items_evicted == 2
      refute stats.overflow?
    end

    test "flags overflow when the fixed tail alone exceeds the budget" do
      context = ctx([user("aaa"), user("one two three four five")])

      {fitted, stats} =
        ContextWindow.fit_with_stats(context, max_tokens: 2, estimator: @estimator)

      assert stats.overflow?
      # Overflow still returns a usable turn rather than an empty one.
      assert contents(fitted) == ["one two three four five"]
    end

    test "returns nil stats when no budget is configured" do
      assert {_ctx, nil} = ContextWindow.fit_with_stats(ctx([user("a")]), [])
    end
  end

  describe "fit_messages/2" do
    test "treats leading system messages as a counted, preserved head" do
      messages = [
        %{role: :system, content: "one two three"},
        %{role: :user, content: "aaa"},
        %{role: :assistant, content: "bbb"},
        %{role: :user, content: "ccc"}
      ]

      fitted = ContextWindow.fit_messages(messages, max_tokens: 4, estimator: @estimator)

      assert Enum.map(fitted, & &1.content) == ["one two three", "ccc"]
    end

    test "keeps assistant tool_calls and their results together" do
      messages = [
        %{role: :user, content: "old"},
        %{role: :assistant, content: "calling", tool_calls: [%{id: "c1"}]},
        %{role: :tool, tool_call_id: "c1", content: "a b c d e"},
        %{role: :user, content: "newest"}
      ]

      fitted = ContextWindow.fit_messages(messages, max_tokens: 2, estimator: @estimator)

      assert Enum.map(fitted, & &1.role) == [:user]
    end

    test "handles string-keyed messages" do
      messages = [
        %{"role" => "user", "content" => "aaa"},
        %{"role" => "assistant", "content" => "bbb"},
        %{"role" => "user", "content" => "ccc"}
      ]

      fitted = ContextWindow.fit_messages(messages, max_tokens: 1, estimator: @estimator)

      assert length(fitted) == 1
      assert Enum.at(fitted, 0)["content"] == "ccc"
    end

    test "pins durable messages" do
      messages = [
        %{role: :assistant, content: "load", tool_calls: [%{id: "s1"}]},
        %{role: :tool, tool_call_id: "s1", content: "skill body", refs: %{durable: true}},
        %{role: :user, content: "aaa"},
        %{role: :user, content: "newest"}
      ]

      fitted = ContextWindow.fit_messages(messages, max_tokens: 1, estimator: @estimator)
      contents = Enum.map(fitted, & &1.content)

      assert "skill body" in contents
      assert "newest" in contents
      refute "aaa" in contents
    end
  end

  describe "transform_request/4" do
    defp request(messages), do: %{messages: messages, llm_opts: [], tools: %{}, model: :model}

    test "is a no-op when no budget is present in the runtime context" do
      messages = List.duplicate(%{role: :user, content: "a b c d e"}, 20)

      assert {:ok, %{}} == ContextWindow.transform_request(request(messages), nil, nil, %{})
    end

    test "is a no-op when the request already fits" do
      messages = [%{role: :user, content: "short"}]

      assert {:ok, %{}} ==
               ContextWindow.transform_request(
                 request(messages),
                 nil,
                 nil,
                 %{max_context_tokens: 1_000}
               )
    end

    test "overrides messages when trimming is needed" do
      messages = [
        %{role: :system, content: "sys"},
        %{role: :user, content: "old one"},
        %{role: :assistant, content: "old reply"},
        %{role: :user, content: "newest"}
      ]

      assert {:ok, %{messages: trimmed}} =
               ContextWindow.transform_request(
                 request(messages),
                 nil,
                 nil,
                 %{max_context_tokens: 2}
               )

      assert Enum.map(trimmed, & &1.content) == ["sys", "newest"]
    end

    test "reads the budget from a nested tool_context" do
      messages = [
        %{role: :user, content: "old"},
        %{role: :user, content: "newest"}
      ]

      assert {:ok, %{messages: trimmed}} =
               ContextWindow.transform_request(
                 request(messages),
                 nil,
                 nil,
                 %{tool_context: %{max_context_tokens: 1}}
               )

      assert length(trimmed) == 1
    end

    test "ignores a non-positive budget" do
      messages = List.duplicate(%{role: :user, content: "a b c"}, 10)

      assert {:ok, %{}} ==
               ContextWindow.transform_request(
                 request(messages),
                 nil,
                 nil,
                 %{max_context_tokens: 0}
               )
    end
  end

  describe "estimation" do
    test "counts assistant tool_calls payloads against the budget" do
      big_args = %{id: "c1", name: "t", arguments: String.duplicate("word ", 50)}

      context =
        ctx([
          %AIContext.Entry{role: :assistant, content: "hi", tool_calls: [big_args]},
          tool_result("c1", "res"),
          user("newest")
        ])

      # The tool_calls payload alone blows a small budget, so the group is dropped.
      assert contents(fit(context, 5)) == ["newest"]
    end

    test "handles list content parts" do
      context =
        ctx([
          %AIContext.Entry{role: :user, content: [%{type: :text, text: "a b c"}]},
          user("newest")
        ])

      assert contents(fit(context, 1)) == ["newest"]
    end

    test "handles nil content without crashing" do
      context = ctx([%AIContext.Entry{role: :assistant, content: nil}, user("newest")])

      # A nil-content entry costs nothing, so it survives a tight budget rather
      # than being evicted for no gain.
      assert contents(fit(context, 1)) == [nil, "newest"]
    end
  end
end
