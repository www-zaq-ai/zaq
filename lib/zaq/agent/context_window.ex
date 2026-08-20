defmodule Zaq.Agent.ContextWindow do
  @moduledoc """
  Bounds an agent's `Jido.AI.Context` to a token budget.

  The system prompt and the current user question are fixed costs and are never
  dropped. Everything else — prior history, assistant turns, tool calls and tool
  results — is variable and evicted oldest-first (FIFO) until the whole context
  fits the budget.

  Two callsites cover three cases:

  - `Zaq.Agent.Plugin.ContextWindowPlugin` — cold spawn (`mount/2`) and warm
    compaction after each completed request.
  - `transform_request/4` — per ReAct turn, wired as the `request_transformer`
    in `Zaq.Agent.Factory`.
  """

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  alias Jido.AI.Context, as: AIContext
  alias Jido.AI.Context.Entry
  alias Zaq.Agent.TokenEstimator

  @default_max_tokens 5_000

  @doc """
  Returns the effective token budget, falling back to #{@default_max_tokens}.
  """
  @spec budget(integer() | nil) :: pos_integer()
  def budget(max_tokens) when is_integer(max_tokens) and max_tokens > 0, do: max_tokens
  def budget(_), do: @default_max_tokens

  @doc """
  Trims `context` to `max_tokens`, evicting the oldest variable entries first.

  The system prompt and the most recent user entry are always kept.
  """
  @spec fit(AIContext.t(), integer() | nil) :: AIContext.t()
  def fit(%AIContext{} = context, max_tokens) do
    max = budget(max_tokens)
    chronological = Enum.reverse(context.entries)
    pinned = last_user_index(chronological)
    remaining = max - fixed_tokens(context, chronological, pinned)

    keep = kept_indexes(chronological, remaining, pinned)

    kept =
      chronological
      |> Enum.with_index()
      |> Enum.filter(fn {_entry, index} -> MapSet.member?(keep, index) end)
      |> Enum.map(&elem(&1, 0))
      |> repair_tool_blocks()

    %{context | entries: Enum.reverse(kept)}
  end

  @impl Jido.AI.Reasoning.ReAct.RequestTransformer
  def transform_request(_request, state, _config, runtime_context) do
    context = state.context
    fitted = fit(context, runtime_context[:memory_context_max_size])

    if fitted.entries == context.entries do
      {:ok, %{}}
    else
      {:ok, %{messages: AIContext.to_messages(fitted)}}
    end
  end

  # Walks newest-first and stops at the first entry that no longer fits, so the
  # survivors are a contiguous run of the most recent entries rather than
  # whichever older ones happen to be small. The pinned index is seeded in and
  # skipped by the walk — it is already charged as a fixed cost and must survive
  # even when a huge entry halts the walk before reaching it.
  defp kept_indexes(chronological, remaining, pinned) do
    base = if is_nil(pinned), do: MapSet.new(), else: MapSet.new([pinned])

    chronological
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while({base, remaining}, fn
      {_entry, ^pinned}, acc ->
        {:cont, acc}

      {entry, index}, {keep, left} ->
        cost = entry_tokens(entry)

        if cost <= left,
          do: {:cont, {MapSet.put(keep, index), left - cost}},
          else: {:halt, {keep, left}}
    end)
    |> elem(0)
  end

  defp fixed_tokens(context, chronological, pinned) do
    prompt_tokens = TokenEstimator.estimate(context.system_prompt || "")

    case pinned do
      nil -> prompt_tokens
      index -> prompt_tokens + entry_tokens(Enum.at(chronological, index))
    end
  end

  defp last_user_index(chronological) do
    chronological
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {entry, index} -> if entry.role == :user, do: index end)
  end

  # An assistant tool call and its results are one indivisible block: providers
  # reject an assistant `tool_calls` message that is not followed by a `tool`
  # message per `tool_call_id`, and reject a `tool` message with no call to
  # answer. Eviction alone cannot split a block — the newest-first walk always
  # reaches the results before the call — but a half-written block can arrive
  # that way when a run dies between `:tool_started` and `:tool_completed`, so
  # the repair runs regardless of whether anything was trimmed.
  #
  # Two passes: drop assistant entries whose calls are not all answered, then
  # drop results left without a call. A partially answered multi-call entry
  # needs both passes to resolve.
  defp repair_tool_blocks(chronological) do
    answered =
      chronological
      |> Enum.filter(&(&1.role == :tool))
      |> MapSet.new(& &1.tool_call_id)

    kept =
      Enum.reject(chronological, fn entry ->
        entry.role == :assistant and unanswered_call?(entry, answered)
      end)

    live_ids =
      kept
      |> Enum.flat_map(fn entry -> entry.tool_calls || [] end)
      |> MapSet.new(&tool_call_id/1)

    Enum.reject(kept, fn entry ->
      entry.role == :tool and not MapSet.member?(live_ids, entry.tool_call_id)
    end)
  end

  defp unanswered_call?(%Entry{tool_calls: calls}, answered) when is_list(calls) do
    Enum.any?(calls, fn call -> not MapSet.member?(answered, tool_call_id(call)) end)
  end

  defp unanswered_call?(_entry, _answered), do: false

  defp tool_call_id(%{id: id}), do: id
  defp tool_call_id(%{"id" => id}), do: id
  defp tool_call_id(_), do: nil

  defp entry_tokens(%Entry{} = entry) do
    TokenEstimator.estimate(to_text(entry.content)) +
      TokenEstimator.estimate(to_text(entry.tool_calls))
  end

  # `TokenEstimator` is word-based, so tool calls are costed via `inspect/1`
  # rather than the JSON that goes on the wire: minified JSON carries almost no
  # whitespace and would be counted as a single word, wildly under-charging a
  # large tool call.
  defp to_text(nil), do: ""
  defp to_text(text) when is_binary(text), do: text
  defp to_text(other), do: inspect(other)
end
