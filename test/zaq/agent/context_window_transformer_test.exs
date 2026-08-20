defmodule Zaq.Agent.ContextWindowTransformerTest do
  @moduledoc """
  Proves the per-turn seam: `Zaq.Agent.ContextWindow` installed as the ReAct
  `request_transformer` bounds every LLM request of a live multi-iteration run,
  reading its budget from the `tool_context` `Zaq.Agent.ServerManager` seeds.

  The assertions are made on the request bodies the LLM actually received, so
  nothing between the transformer and the wire is stubbed out.
  """

  use ExUnit.Case, async: false

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.{ContextWindow, TokenEstimator}
  alias Zaq.TestSupport.LLMSSEStub

  @budget 120

  # The budget is enforced against ContextWindow's own estimate of the entries it
  # holds. What lands on the wire is a re-serialization of those entries (JSON
  # tool calls, ReAct's post-transform output instructions), so the two counts
  # cannot be identical. This allowance covers that gap and nothing more — the
  # test below also asserts the payload does not grow across iterations, which is
  # the property a stale allowance could never fake.
  @serialization_allowance 10

  defmodule EchoTool do
    @moduledoc false
    use Jido.Action,
      name: "echo",
      description: "Echoes a long payload back",
      schema: [text: [type: :string, required: true]]

    def run(%{text: text}, _context) do
      {:ok, %{result: String.duplicate("#{text} padding words here ", 12)}}
    end
  end

  defmodule Agent do
    @moduledoc false
    use Jido.AI.Agent,
      name: "context_window_probe",
      description: "probe agent",
      request_policy: :reject,
      request_transformer: Zaq.Agent.ContextWindow,
      tools: [EchoTool]

    def strategy_opts, do: super() |> Keyword.delete(:model)
  end

  defp start_stub(tool_turns) do
    {child_spec, base_url} = LLMSSEStub.server(tool_turns, self())
    {:ok, _} = start_supervised(child_spec)
    base_url
  end

  defp start_agent(base_url, context, budget) do
    {:ok, pid} =
      start_supervised(
        {Jido.AgentServer,
         [
           agent: Agent,
           jido: Zaq.Agent.Jido,
           registry: Jido.registry_name(Zaq.Agent.Jido),
           id: "ctx-window-#{System.unique_integer([:positive])}",
           initial_state: %{
             model: %{
               provider: :openai,
               id: "test-model",
               base_url: base_url,
               api_key: "test-key"
             },
             tool_context: %{memory_context_max_size: budget},
             context: context
           }
         ]}
      )

    pid
  end

  # ZAQ injects the provider key through llm_opts (see Zaq.Agent.ProviderSpec),
  # not onto the model spec, so the stub credential goes the same way.
  defp ask_opts, do: [timeout: 30_000, llm_opts: [api_key: "test-key"]]

  defp collect_requests(acc \\ []) do
    receive do
      {:llm_request, turn, body} -> collect_requests([{turn, body} | acc])
    after
      0 -> Enum.sort_by(acc, &elem(&1, 0))
    end
  end

  # Mirrors Zaq.Agent.ContextWindow's own accounting so the assertion measures
  # the budget it enforces rather than a differently-counted approximation.
  defp payload_tokens(body) do
    Enum.reduce(body["messages"], 0, fn msg, acc ->
      acc + TokenEstimator.estimate(to_string(msg["content"] || "")) + tool_call_tokens(msg)
    end)
  end

  defp tool_call_tokens(%{"tool_calls" => calls}) when is_list(calls),
    do: TokenEstimator.estimate(inspect(calls))

  defp tool_call_tokens(_), do: 0

  defp context_tokens(%AIContext{} = ctx) do
    TokenEstimator.estimate(ctx.system_prompt || "") +
      Enum.reduce(ctx.entries, 0, fn e, acc ->
        acc + TokenEstimator.estimate(to_string(e.content || ""))
      end)
  end

  defp bloated_context do
    Enum.reduce(1..40, AIContext.new(system_prompt: "you are a helpful assistant"), fn i, ctx ->
      ctx
      |> AIContext.append_user("old user message number #{i} with some padding words")
      |> AIContext.append_assistant("old assistant reply number #{i} with padding words")
    end)
  end

  test "bounds every request of a multi-iteration run and never lets the payload grow unbounded" do
    base_url = start_stub(3)
    pid = start_agent(base_url, bloated_context(), @budget)

    assert {:ok, _} = Agent.ask_sync(pid, "what is the answer", ask_opts())

    requests = collect_requests()

    assert length(requests) >= 4,
           "expected 3 tool iterations plus a final turn, got #{length(requests)}"

    for {turn, body} <- requests do
      assert payload_tokens(body) <= @budget + @serialization_allowance,
             "turn #{turn} sent #{payload_tokens(body)} tokens, budget is #{@budget}"
    end

    # The real regression this guards: without per-turn trimming each iteration
    # appends a tool call and its result and never gives anything back, so the
    # last request is strictly larger than the first. Here it is not.
    sizes = Enum.map(requests, fn {_turn, body} -> payload_tokens(body) end)

    assert List.last(sizes) <= List.first(sizes),
           "payload grew across iterations: #{inspect(sizes)}"

    # The untrimmed context is an order of magnitude past the budget, so the
    # bound above is the transformer working, not a small context flattering it.
    assert ContextWindow.fit(bloated_context(), 1_000_000) |> context_tokens() > @budget * 5
  end

  test "the system prompt and the current question survive every trimmed request" do
    base_url = start_stub(1)
    pid = start_agent(base_url, bloated_context(), @budget)

    assert {:ok, _} = Agent.ask_sync(pid, "the current question", ask_opts())

    for {turn, body} <- collect_requests() do
      messages = body["messages"]

      assert hd(messages)["role"] == "system",
             "turn #{turn} lost the system prompt"

      assert Enum.any?(messages, &(&1["content"] == "the current question")),
             "turn #{turn} lost the current user question"
    end
  end
end
