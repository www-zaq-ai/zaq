defmodule Zaq.Agent.ContextWindowTest do
  use ExUnit.Case, async: true

  alias Jido.AI.Context, as: AIContext
  alias Jido.AI.Context.Entry
  alias Zaq.Agent.{ContextWindow, TokenEstimator}

  # TokenEstimator is words * 1.3 rounded up, so a 10-word entry costs 13 tokens.
  defp words(n), do: Enum.map_join(1..n, " ", fn i -> "w#{i}" end)

  defp context(entries, opts \\ []) do
    Enum.reduce(entries, AIContext.new(opts), &AIContext.append(&2, &1))
  end

  defp entry(role, content, extra \\ %{}) do
    struct!(%Entry{role: role, content: content}, extra)
  end

  defp roles_and_content(%AIContext{} = ctx) do
    ctx |> AIContext.to_messages() |> Enum.map(&{&1.role, &1.content})
  end

  describe "budget/1" do
    test "uses the given size when positive" do
      assert ContextWindow.budget(120) == 120
    end

    test "falls back to the default for nil and non-positive sizes" do
      assert ContextWindow.budget(nil) == 5_000
      assert ContextWindow.budget(0) == 5_000
      assert ContextWindow.budget(-1) == 5_000
    end
  end

  describe "fit/2 — returns a clean context" do
    test "returns a %Jido.AI.Context{} preserving id and system prompt" do
      ctx = context([entry(:user, "hello")], system_prompt: "sys", id: "ctx-1")

      fitted = ContextWindow.fit(ctx, 10)

      assert %AIContext{id: "ctx-1", system_prompt: "sys"} = fitted
      assert Enum.all?(fitted.entries, &match?(%Entry{}, &1))
    end

    test "an empty context stays empty" do
      ctx = AIContext.new(system_prompt: "sys")

      assert ContextWindow.fit(ctx, 5).entries == []
    end

    test "a context already within budget is untouched" do
      ctx =
        context(
          [entry(:user, words(2)), entry(:assistant, words(2)), entry(:user, words(2))],
          system_prompt: words(2)
        )

      assert ContextWindow.fit(ctx, 5_000) == ctx
    end
  end

  describe "fit/2 — FIFO eviction" do
    test "evicts oldest entries first and keeps chronological order" do
      # Fixed: system prompt (4) + current question (3) = 7. A budget of 25 leaves
      # 18, which fits the newest 15-token history entry but not the one before it.
      ctx =
        context(
          [
            entry(:user, words(10)),
            entry(:assistant, "oldest-assistant " <> words(10)),
            entry(:user, "newest-history " <> words(10)),
            entry(:user, "current question")
          ],
          system_prompt: "you are helpful"
        )

      fitted = ContextWindow.fit(ctx, 25)

      assert [
               {:system, "you are helpful"},
               {:user, "newest-history" <> _},
               {:user, "current question"}
             ] = roles_and_content(fitted)
    end

    test "drops everything variable when only the fixed cost fits" do
      ctx =
        context(
          [
            entry(:user, words(10)),
            entry(:assistant, words(10)),
            entry(:user, "current question")
          ],
          system_prompt: "sys"
        )

      fitted = ContextWindow.fit(ctx, 6)

      assert roles_and_content(fitted) == [
               {:system, "sys"},
               {:user, "current question"}
             ]
    end

    test "keeps the current question even when it alone exceeds the budget" do
      ctx =
        context(
          [entry(:user, words(10)), entry(:user, "the current " <> words(40))],
          system_prompt: "sys"
        )

      fitted = ContextWindow.fit(ctx, 5)

      assert [{:system, "sys"}, {:user, "the current" <> _}] = roles_and_content(fitted)
    end

    test "with no user entry only the system prompt is fixed" do
      ctx =
        context(
          [entry(:assistant, words(10)), entry(:assistant, "newest " <> words(10))],
          system_prompt: "sys"
        )

      fitted = ContextWindow.fit(ctx, 20)

      assert [{:system, "sys"}, {:assistant, "newest" <> _}] = roles_and_content(fitted)
    end

    test "counts tool_calls toward an assistant entry's cost" do
      calls = [%{id: "call_1", name: "search", arguments: %{query: words(30)}}]

      ctx =
        context(
          [
            entry(:assistant, "calling", %{tool_calls: calls}),
            entry(:user, "current question")
          ],
          system_prompt: "sys"
        )

      # "calling" alone is 2 tokens and would fit; the serialized tool_calls push
      # it past the 10 tokens left after the fixed cost.
      assert roles_and_content(ContextWindow.fit(ctx, 13)) == [
               {:system, "sys"},
               {:user, "current question"}
             ]
    end
  end

  describe "fit/2 — tool call integrity" do
    test "drops a tool result whose assistant tool call was evicted" do
      calls = [%{id: "call_1", name: "search", arguments: %{query: words(20)}}]

      ctx =
        context(
          [
            entry(:assistant, "calling", %{tool_calls: calls}),
            entry(:tool, "result", %{tool_call_id: "call_1"}),
            entry(:user, "current question")
          ],
          system_prompt: "sys"
        )

      fitted = ContextWindow.fit(ctx, 13)

      assert roles_and_content(fitted) == [
               {:system, "sys"},
               {:user, "current question"}
             ]
    end

    test "drops an assistant tool call whose result is absent from the context" do
      # A run that died between :tool_started and :tool_completed commits a turn
      # with the call but no result. Providers reject an assistant tool_calls
      # message that is not followed by a tool message per tool_call_id, so the
      # dangling call must not reach them — even when nothing needs trimming.
      calls = [%{id: "call_1", name: "search", arguments: %{}}]

      ctx =
        context(
          [
            entry(:user, "older"),
            entry(:assistant, "calling", %{tool_calls: calls}),
            entry(:user, "current question")
          ],
          system_prompt: "sys"
        )

      assert roles_and_content(ContextWindow.fit(ctx, 5_000)) == [
               {:system, "sys"},
               {:user, "older"},
               {:user, "current question"}
             ]
    end

    test "drops an assistant entry when only some of its tool calls were answered" do
      calls = [
        %{id: "call_1", name: "search", arguments: %{}},
        %{id: "call_2", name: "search", arguments: %{}}
      ]

      ctx =
        context(
          [
            entry(:assistant, "calling", %{tool_calls: calls}),
            entry(:tool, "only the first result", %{tool_call_id: "call_1"}),
            entry(:user, "current question")
          ],
          system_prompt: "sys"
        )

      # The surviving result goes too — it would otherwise be orphaned by the
      # assistant entry's removal.
      assert roles_and_content(ContextWindow.fit(ctx, 5_000)) == [
               {:system, "sys"},
               {:user, "current question"}
             ]
    end

    test "keeps a fully answered multi-call assistant entry" do
      calls = [
        %{id: "call_1", name: "search", arguments: %{}},
        %{id: "call_2", name: "search", arguments: %{}}
      ]

      ctx =
        context(
          [
            entry(:assistant, "calling", %{tool_calls: calls}),
            entry(:tool, "first", %{tool_call_id: "call_1"}),
            entry(:tool, "second", %{tool_call_id: "call_2"}),
            entry(:user, "current question")
          ],
          system_prompt: "sys"
        )

      assert roles_and_content(ContextWindow.fit(ctx, 5_000)) == [
               {:system, "sys"},
               {:assistant, "calling"},
               {:tool, "first"},
               {:tool, "second"},
               {:user, "current question"}
             ]
    end

    test "keeps a tool result when its assistant tool call survives" do
      calls = [%{id: "call_1", name: "search", arguments: %{}}]

      ctx =
        context(
          [
            entry(:user, words(20)),
            entry(:assistant, "calling", %{tool_calls: calls}),
            entry(:tool, "result", %{tool_call_id: "call_1"}),
            entry(:user, "current question")
          ],
          system_prompt: "sys"
        )

      fitted = ContextWindow.fit(ctx, 40)

      assert roles_and_content(fitted) == [
               {:system, "sys"},
               {:assistant, "calling"},
               {:tool, "result"},
               {:user, "current question"}
             ]
    end
  end

  describe "fit/2 — stability across repeated ReAct turns" do
    test "stays within budget as tool calls and results accumulate" do
      budget = 60

      final =
        Enum.reduce(1..12, context([entry(:user, "current question")], system_prompt: "sys"), fn
          i, ctx ->
            calls = [%{id: "call_#{i}", name: "search", arguments: %{q: words(5)}}]

            ctx
            |> AIContext.append(entry(:assistant, words(8), %{tool_calls: calls}))
            |> AIContext.append(entry(:tool, words(8), %{tool_call_id: "call_#{i}"}))
            |> ContextWindow.fit(budget)
        end)

      assert total_tokens(final) <= budget
      # The pinned question and the most recent turn survive every pass.
      assert [{:system, "sys"} | rest] = roles_and_content(final)
      assert {:user, "current question"} in rest
      assert Enum.any?(rest, &match?({:tool, _}, &1))
    end
  end

  describe "transform_request/4" do
    test "returns no overrides when the context already fits" do
      ctx = context([entry(:user, "hi")], system_prompt: "sys")

      assert {:ok, %{}} =
               ContextWindow.transform_request(%{}, %{context: ctx}, %{}, %{
                 memory_context_max_size: 5_000
               })
    end

    test "overrides messages with the trimmed projection" do
      ctx =
        context(
          [entry(:user, words(30)), entry(:user, "current question")],
          system_prompt: "sys"
        )

      assert {:ok, %{messages: messages}} =
               ContextWindow.transform_request(%{}, %{context: ctx}, %{}, %{
                 memory_context_max_size: 6
               })

      assert Enum.map(messages, & &1.role) == [:system, :user]
    end

    test "falls back to the default budget when the runtime context has no size" do
      ctx = context([entry(:user, words(30)), entry(:user, "current question")])

      assert {:ok, %{}} = ContextWindow.transform_request(%{}, %{context: ctx}, %{}, %{})
    end
  end

  defp total_tokens(%AIContext{} = ctx) do
    TokenEstimator.estimate(ctx.system_prompt || "") +
      Enum.reduce(ctx.entries, 0, fn e, acc ->
        acc + TokenEstimator.estimate(text(e.content)) +
          TokenEstimator.estimate(text(e.tool_calls))
      end)
  end

  defp text(nil), do: ""
  defp text(t) when is_binary(t), do: t
  defp text(other), do: inspect(other)
end
