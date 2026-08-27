defmodule Zaq.Agent.ContextWindow do
  @moduledoc """
  FIFO context-window budgeting for agent conversations.

  Keeps a `Jido.AI.Context` (or a projected message list) within a token budget —
  `ConfiguredAgent.memory_context_max_size` — using a **fixed head, FIFO middle,
  fixed tail** policy:

  - **Head (fixed)** — the system prompt. Never evicted, but always *counted*
    against the budget. In `Jido.AI.Context` the system prompt is a struct field
    rather than an entry, so it is structurally impossible to evict; the only
    thing this module adds is making it consume budget rather than silently
    overflow it.
  - **Tail (fixed)** — never evicted. What counts as the tail depends on the
    `:anchor` option:
      * `:turn` (default) — the last `:user` entry and everything after it, i.e.
        the current turn: user message, assistant tool calls, tool results.
        Correct **only where a run is actually in flight**, so that the entry
        being protected really is the turn being served. In practice that means
        `transform_request/4` and nothing else.
      * `:newest` — the newest group only. Correct everywhere no run is in
        flight — cold hydration and warm compaction both qualify. There the most
        recent `:user` entry is just settled history, so anchoring on it pins the
        whole trailing turn; when that turn is a fat tool sequence there is then
        nothing left to evict and the budget stops being enforced.
    Either way the tail is non-empty, so a trim can never return an empty context.
  - **Middle (FIFO)** — everything in between, dropped oldest-first until the
    total fits.

  ## Why groups, not entries

  Eviction operates on *groups*, never on individual entries. An assistant entry
  carrying `tool_calls` plus every `:tool` entry matching those `tool_call_id`s
  form one atomic unit. Both OpenAI and Anthropic reject an orphan `tool` message
  whose assistant stub was dropped, and reject an assistant `tool_calls` stub
  whose results are missing — so a naive per-entry FIFO produces 400s. Dropping
  whole groups is what makes this safe.

  ## Pinned groups

  A group is pinned (never evicted from the middle) when any of its entries
  carries `refs: %{durable: true}`. `jido_ai` tags `load_skill` results this way;
  evicting them would drop a skill body the agent is still relying on. `:system`
  entries are pinned for the same reason.

  ## Three call sites

  - **Cold span** — `Zaq.Agent.HistoryLoader` calls `fit/2` after building the
    context from DB history, bounding hydration at spawn.
  - **Warm span, per turn** — `transform_request/4` implements
    `Jido.AI.Reasoning.ReAct.RequestTransformer` and runs on *every* LLM turn,
    bounding what actually goes on the wire. This is the load-bearing half: it is
    the only hook that can contain a single run whose tool results balloon across
    iterations. It is **non-destructive** — it rewrites the outgoing
    `request.messages` and leaves `state.context` untouched.
  - **Warm span, at rest** — `Zaq.Agent.Factory`'s `on_after_cmd` hook calls `fit/2` on
    the committed context as soon as a run settles, so the stored thread is held
    to the budget too rather than only the payload. It writes the context
    directly, in-process, so nothing re-orders entries behind it.

  ## Budget resolution (warm span)

  The per-agent budget reaches the transformer through the ReAct runtime context,
  which `Jido.AI.Reasoning.ReAct.Strategy` builds by merging the per-run
  `tool_context` over the agent's `base_tool_context`. `Zaq.Agent.Factory` passes
  `tool_context: %{max_context_tokens: ...}` on each ask. When no budget is
  present the transformer is a no-op, so agents without
  `memory_context_max_size` configured are unaffected.

  ## Token estimation

  Defaults to `Zaq.Agent.TokenEstimator.estimate/1` (word count × 1.3). That
  heuristic under-counts JSON tool results, which are exactly the payloads that
  drive the problem — pass `:estimator` to override.
  """

  require Logger

  alias Jido.AI.Context, as: AIContext
  alias Zaq.Agent.TokenEstimator

  @behaviour Jido.AI.Reasoning.ReAct.RequestTransformer

  @telemetry_event [:zaq, :agent, :context_window, :fit]

  @type estimator :: (String.t() -> non_neg_integer())

  @type stats :: %{
          budget: pos_integer(),
          head_tokens: non_neg_integer(),
          tokens_before: non_neg_integer(),
          tokens_after: non_neg_integer(),
          groups_total: non_neg_integer(),
          groups_evicted: non_neg_integer(),
          items_evicted: non_neg_integer(),
          overflow?: boolean()
        }

  @doc """
  Fits a `Jido.AI.Context` within `:max_tokens`, returning a trimmed context.

  The `system_prompt` field is preserved as-is and counted against the budget.
  Returns the context unchanged when it already fits or when `:max_tokens` is
  absent/non-positive.

  ## Options

    * `:max_tokens` — token budget. Required; without it this is a no-op.
    * `:anchor` — `:turn` (default) or `:newest`; see the module docs.
    * `:estimator` — 1-arity fun from text to token count.
      Default `Zaq.Agent.TokenEstimator.estimate/1`.
    * `:label` — string included in telemetry/log metadata to identify the call
      site (e.g. `"cold"`, `"warm"`).
  """
  @spec fit(AIContext.t(), keyword()) :: AIContext.t()
  def fit(%AIContext{} = context, opts) do
    {context, _stats} = fit_with_stats(context, opts)
    context
  end

  @doc """
  Same as `fit/2` but also returns the eviction `t:stats/0`.
  """
  @spec fit_with_stats(AIContext.t(), keyword()) :: {AIContext.t(), stats() | nil}
  def fit_with_stats(%AIContext{} = context, opts) do
    case budget(opts) do
      nil ->
        {context, nil}

      max_tokens ->
        estimator = estimator(opts)
        head_tokens = estimate_text(context.system_prompt, estimator)

        # Entries are stored newest-first; the algorithm works chronologically.
        chronological = Enum.reverse(context.entries)

        {kept, stats} =
          select(
            chronological,
            &entry_meta/1,
            head_tokens,
            max_tokens,
            estimator,
            anchor(opts)
          )

        report(stats, opts)

        {%{context | entries: Enum.reverse(kept)}, stats}
    end
  end

  @doc """
  Fits a projected message list (the output of `Jido.AI.Context.to_messages/2`).

  Leading `:system` messages are treated as the fixed head: preserved in place
  and counted against the budget. Any `:system` message deeper in the list is
  pinned rather than evicted.
  """
  @spec fit_messages([map()], keyword()) :: [map()]
  def fit_messages(messages, opts) when is_list(messages) do
    {messages, _stats} = fit_messages_with_stats(messages, opts)
    messages
  end

  @doc """
  Same as `fit_messages/2` but also returns the eviction `t:stats/0`.
  """
  @spec fit_messages_with_stats([map()], keyword()) :: {[map()], stats() | nil}
  def fit_messages_with_stats(messages, opts) when is_list(messages) do
    case budget(opts) do
      nil ->
        {messages, nil}

      max_tokens ->
        estimator = estimator(opts)
        meta_fun = &message_meta/1
        {head, body} = Enum.split_while(messages, &(message_role(&1) == :system))

        head_tokens =
          Enum.sum(Enum.map(head, fn item -> estimate_item(item, meta_fun, estimator) end))

        {kept, stats} =
          select(
            body,
            meta_fun,
            head_tokens,
            max_tokens,
            estimator,
            anchor(opts)
          )

        report(stats, opts)

        {head ++ kept, stats}
    end
  end

  # -- RequestTransformer -----------------------------------------------------

  @doc """
  Bounds the outgoing message list on every ReAct turn.

  Reads the budget from the runtime context (`:max_context_tokens`, either at the
  top level or nested under `:tool_context`) and trims `request.messages` to fit.
  Returns `{:ok, %{}}` — an explicit no-op — when no budget is configured or the
  request already fits, so no unnecessary override churn reaches the runner.
  """
  @impl Jido.AI.Reasoning.ReAct.RequestTransformer
  def transform_request(request, _state, _config, runtime_context) do
    case runtime_budget(runtime_context) do
      nil ->
        {:ok, %{}}

      max_tokens ->
        messages = Map.get(request, :messages, [])

        opts = [
          max_tokens: max_tokens,
          label: "warm",
          request_id: Map.get(runtime_context, :request_id)
        ]

        case fit_messages_with_stats(messages, opts) do
          {_kept, nil} -> {:ok, %{}}
          {_kept, %{groups_evicted: 0}} -> {:ok, %{}}
          {kept, _stats} -> {:ok, %{messages: kept}}
        end
    end
  end

  # -- Core algorithm ---------------------------------------------------------

  # Groups items into atomic units, marks the fixed tail and pinned groups, then
  # drops non-tail, non-pinned groups oldest-first until the budget is met.
  defp select(items, meta_fun, head_tokens, max_tokens, estimator, anchor) do
    groups = group(items, meta_fun)
    tail_start = tail_start_index(groups, meta_fun, anchor)

    annotated =
      groups
      |> Enum.with_index()
      |> Enum.map(fn {group, index} ->
        %{
          items: group,
          tokens: Enum.sum(Enum.map(group, &estimate_item(&1, meta_fun, estimator))),
          pinned?: Enum.any?(group, &pinned?(&1, meta_fun)),
          tail?: index >= tail_start
        }
      end)

    tokens_before = head_tokens + Enum.sum(Enum.map(annotated, & &1.tokens))

    {kept, evicted} = evict(annotated, head_tokens, max_tokens)

    tokens_after = head_tokens + Enum.sum(Enum.map(kept, & &1.tokens))

    stats = %{
      budget: max_tokens,
      head_tokens: head_tokens,
      tokens_before: tokens_before,
      tokens_after: tokens_after,
      groups_total: length(annotated),
      groups_evicted: length(evicted),
      items_evicted: evicted |> Enum.map(&length(&1.items)) |> Enum.sum(),
      overflow?: tokens_after > max_tokens
    }

    {Enum.flat_map(kept, & &1.items), stats}
  end

  # FIFO: walk oldest-first, dropping every droppable group until we fit. A group
  # is droppable when it is neither in the fixed tail nor pinned. Groups are kept
  # in their original order; only whole groups are ever removed.
  defp evict(groups, head_tokens, max_tokens) do
    total = head_tokens + Enum.sum(Enum.map(groups, & &1.tokens))

    {reversed_kept, evicted, _total} =
      Enum.reduce(groups, {[], [], total}, fn group, {kept, evicted, running} ->
        droppable? = not group.tail? and not group.pinned?

        if droppable? and running > max_tokens do
          {kept, [group | evicted], running - group.tokens}
        else
          {[group | kept], evicted, running}
        end
      end)

    {Enum.reverse(reversed_kept), Enum.reverse(evicted)}
  end

  # An assistant item carrying tool_calls absorbs the following tool items whose
  # tool_call_id it owns. Everything else is its own singleton group. Tool items
  # with no matching assistant (e.g. imported history) stay singletons rather
  # than crashing.
  defp group([], _meta_fun), do: []

  defp group([item | rest], meta_fun) do
    meta = meta_fun.(item)

    case tool_call_ids(meta) do
      [] ->
        [[item] | group(rest, meta_fun)]

      ids ->
        id_set = MapSet.new(ids)
        {results, remaining} = take_tool_results(rest, id_set, meta_fun, [])
        [[item | results] | group(remaining, meta_fun)]
    end
  end

  defp take_tool_results([item | rest] = all, id_set, meta_fun, acc) do
    meta = meta_fun.(item)

    if meta.role == :tool and MapSet.member?(id_set, meta.tool_call_id) do
      take_tool_results(rest, id_set, meta_fun, [item | acc])
    else
      {Enum.reverse(acc), all}
    end
  end

  defp take_tool_results([], _id_set, _meta_fun, acc), do: {Enum.reverse(acc), []}

  # Under the :turn anchor the fixed tail begins at the last group headed by a
  # :user item — that group plus everything after it is the current turn. With no
  # user group at all (and under the :newest anchor) we protect the newest group
  # instead, so FIFO can never empty the list.
  defp tail_start_index([], _meta_fun, _anchor), do: 0

  defp tail_start_index(groups, _meta_fun, :newest), do: length(groups) - 1

  defp tail_start_index(groups, meta_fun, :turn) do
    groups
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {[first | _], index}, acc ->
      if meta_fun.(first).role == :user, do: index, else: acc
    end)
    |> case do
      nil -> length(groups) - 1
      index -> index
    end
  end

  # -- Metadata extraction ----------------------------------------------------
  #
  # Both shapes normalize to the same meta map so the algorithm above stays
  # agnostic about whether it is looking at Context entries or projected
  # messages.

  defp entry_meta(%AIContext.Entry{} = entry) do
    %{
      role: entry.role,
      tool_calls: entry.tool_calls,
      tool_call_id: entry.tool_call_id,
      refs: entry.refs,
      content: entry.content,
      thinking: entry.thinking
    }
  end

  defp message_meta(message) when is_map(message) do
    %{
      role: message_role(message),
      tool_calls: get_field(message, :tool_calls),
      tool_call_id: get_field(message, :tool_call_id),
      refs: get_field(message, :refs),
      content: get_field(message, :content),
      thinking: get_field(message, :thinking)
    }
  end

  defp message_role(message) when is_map(message) do
    case get_field(message, :role) do
      role when is_atom(role) -> role
      "user" -> :user
      "assistant" -> :assistant
      "tool" -> :tool
      "system" -> :system
      other -> other
    end
  end

  defp get_field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp tool_call_ids(%{role: :assistant, tool_calls: tool_calls}) when is_list(tool_calls) do
    tool_calls
    |> Enum.map(&tool_call_id/1)
    |> Enum.reject(&is_nil/1)
  end

  defp tool_call_ids(_meta), do: []

  defp tool_call_id(tool_call) when is_map(tool_call), do: get_field(tool_call, :id)
  defp tool_call_id(_tool_call), do: nil

  # `refs.durable` marks entries that must survive trimming — jido_ai tags
  # load_skill results this way. System entries are pinned on the same grounds.
  defp pinned?(item, meta_fun) do
    meta = meta_fun.(item)

    meta.role == :system or durable?(meta.refs)
  end

  defp durable?(refs) when is_map(refs) do
    Map.get(refs, :durable) == true or Map.get(refs, "durable") == true
  end

  defp durable?(_refs), do: false

  # -- Estimation -------------------------------------------------------------

  defp estimate_item(item, meta_fun, estimator) do
    meta = meta_fun.(item)

    estimate_text(meta.content, estimator) +
      estimate_text(meta.thinking, estimator) +
      estimate_tool_calls(meta.tool_calls, estimator)
  end

  defp estimate_tool_calls(tool_calls, estimator) when is_list(tool_calls) do
    estimate_text(inspect(tool_calls), estimator)
  end

  defp estimate_tool_calls(_tool_calls, _estimator), do: 0

  defp estimate_text(nil, _estimator), do: 0
  defp estimate_text(text, estimator) when is_binary(text), do: estimator.(text)

  defp estimate_text(parts, estimator) when is_list(parts) do
    parts
    |> Enum.map_join(" ", &part_text/1)
    |> estimator.()
  end

  defp estimate_text(other, estimator), do: estimator.(inspect(other))

  defp part_text(part) when is_map(part) do
    case get_field(part, :text) || get_field(part, :thinking) do
      text when is_binary(text) -> text
      _ -> inspect(part)
    end
  end

  defp part_text(part) when is_binary(part), do: part
  defp part_text(part), do: inspect(part)

  # -- Options / reporting ----------------------------------------------------

  defp budget(opts) do
    case Keyword.get(opts, :max_tokens) do
      value when is_integer(value) and value > 0 -> value
      _ -> nil
    end
  end

  defp estimator(opts) do
    case Keyword.get(opts, :estimator) do
      fun when is_function(fun, 1) -> fun
      _ -> &TokenEstimator.estimate/1
    end
  end

  defp anchor(opts) do
    case Keyword.get(opts, :anchor, :turn) do
      :newest -> :newest
      _ -> :turn
    end
  end

  defp runtime_budget(runtime_context) when is_map(runtime_context) do
    nested = Map.get(runtime_context, :tool_context) || Map.get(runtime_context, "tool_context")

    positive_integer(get_field(runtime_context, :max_context_tokens)) ||
      positive_integer(is_map(nested) && get_field(nested, :max_context_tokens))
  end

  defp runtime_budget(_runtime_context), do: nil

  defp positive_integer(value) when is_integer(value) and value > 0, do: value
  defp positive_integer(_value), do: nil

  defp report(%{groups_evicted: 0, overflow?: false}, _opts), do: :ok

  defp report(stats, opts) do
    metadata =
      stats
      |> Map.take([
        :budget,
        :tokens_before,
        :tokens_after,
        :groups_evicted,
        :items_evicted,
        :overflow?
      ])
      |> Map.put(:label, Keyword.get(opts, :label, "unknown"))
      |> Map.put(:request_id, Keyword.get(opts, :request_id))

    :telemetry.execute(
      @telemetry_event,
      Map.take(stats, [:tokens_before, :tokens_after, :groups_evicted, :items_evicted]),
      metadata
    )

    # Overflow means the fixed head + tail alone exceed the budget — nothing left
    # to evict. We still send, because a truncated turn beats a broken one, but
    # it means memory_context_max_size is too small for this agent's turn size.
    if stats.overflow? do
      Logger.warning(
        "context window overflow: head+tail exceed budget " <>
          "(budget=#{stats.budget}, tokens=#{stats.tokens_after}, label=#{metadata.label})"
      )
    end

    :ok
  end
end
