defmodule Zaq.Agent.Tools.Accounts.History do
  @moduledoc """
  Recalls a person's past conversations by topic and/or time period.

  Serves requests like "what did we decide about Company X?", "what was the
  plan I asked for 3 days ago?", or "I can't remember last week's topic" —
  results are grouped per conversation with their titles so the caller can
  cite where a decision came from.

  ## Identity and permissions

  The person whose history is fetched is resolved from the **trusted execution
  context**, never from LLM-supplied parameters:

  - workflow path: `ctx[:actor]["person"]["id"]` — set by `StepRunner` from
    the workflow run's normalized `source_event.actor`
  - chat path: `ctx[:person_id]` — set by the agent pipeline from the
    channel-resolved author

  The `person_id` **parameter** is honored only when the context carries an
  explicit `skip_permissions: true` (machine/admin runs targeting a person).
  Without a resolvable identity the tool returns `{:error, :unauthorized}`;
  nil or blank values never resolve to an identity.

  ## Schema

  - `query`                     — optional. Topic/keywords searched in titles and message content.
  - `last_n_days`               — optional positive integer look-back window (e.g. 7 for
                                  the last week). Wins over explicit dates.
  - `from_date` / `to_date`     — optional ISO 8601 dates (inclusive bounds).
  - `conversation_limit`        — optional (default: 10).
  - `messages_per_conversation` — optional (default: 50).
  - `person_id`                 — optional. Machine/admin runs only (see above).

  ## Example

      # chat: "what did we decide about Company X?"
      History.run(%{query: "Company X"}, %{person_id: 42})

      # workflow machine run targeting a person
      History.run(%{person_id: 7, last_n_days: 30}, %{skip_permissions: true})
      # => {:ok, %{conversations: [%{id: ..., title: ..., updated_at: ..., messages: [...]}]}}
  """

  use Zaq.Engine.Workflows.Action,
    name: "fetch_history",
    description:
      "Search and recall the requesting person's past conversations by topic and/or time period.",
    schema: [
      query: [
        type: :string,
        required: false,
        doc: "Topic or keywords to search in conversation titles and message content."
      ],
      last_n_days: [
        type: :pos_integer,
        required: false,
        doc:
          "Look back this many days from now (e.g. 1 for today, 7 for the last week, 35 for roughly the last month). Takes precedence over from_date/to_date."
      ],
      from_date: [
        type: :string,
        required: false,
        doc: "ISO 8601 date (YYYY-MM-DD), inclusive lower bound on conversation activity."
      ],
      to_date: [
        type: :string,
        required: false,
        doc: "ISO 8601 date (YYYY-MM-DD), inclusive upper bound on conversation activity."
      ],
      conversation_limit: [
        type: :integer,
        required: false,
        default: 10,
        doc: "Maximum number of conversations to fetch."
      ],
      messages_per_conversation: [
        type: :integer,
        required: false,
        default: 50,
        doc: "Maximum number of messages to include per conversation."
      ],
      person_id: [
        type: :any,
        required: false,
        doc:
          "Target person ID. Honored only on machine/admin runs (skip_permissions); otherwise ignored — identity comes from the execution context."
      ]
    ],
    output_schema: [
      conversations: [
        # NimbleOptions has no bare :list type — the chat-path output validator
        # (Jido.Action.Exec) rejects it at tool-call time.
        type: {:list, :map},
        required: true,
        doc: "Conversations (id, title, updated_at) each with their recent messages."
      ],
      metadata: [
        type: :map,
        required: true,
        doc: "Message counts and first/last message dates for the loaded conversations."
      ]
    ]

  require Logger

  alias Zaq.Engine.Conversations
  alias Zaq.Identity.ActorNormalizer

  @impl Jido.Action
  def run(params, ctx) do
    with {:ok, person_id} <- effective_person_id(params, ctx),
         {:ok, range} <- resolve_range(params) do
      fetch_conversations(person_id, params, range)
    end
  end

  # ── Identity resolution ──────────────────────────────────────────────
  #
  # The LLM controls params; the execution context is trusted. Identity must
  # therefore come from ctx, except for explicit machine/admin runs.

  defp effective_person_id(params, ctx) do
    if ctx[:skip_permissions] == true do
      case ActorNormalizer.normalize_id(params[:person_id]) || context_person_id(ctx) do
        nil -> {:error, :missing_person_id}
        id -> {:ok, id}
      end
    else
      case context_person_id(ctx) do
        nil -> {:error, :unauthorized}
        id -> {:ok, id}
      end
    end
  end

  defp context_person_id(ctx) do
    ActorNormalizer.normalize_id(ActorNormalizer.person_id(ctx[:actor])) ||
      ActorNormalizer.normalize_id(ctx[:person_id])
  end

  # ── Time range resolution ────────────────────────────────────────────

  defp resolve_range(params) do
    cond do
      not is_nil(params[:last_n_days]) -> n_days_range(params[:last_n_days])
      params[:from_date] || params[:to_date] -> date_range(params[:from_date], params[:to_date])
      true -> {:ok, {nil, nil}}
    end
  end

  defp n_days_range(days) when is_integer(days) and days > 0,
    do: {:ok, {DateTime.add(DateTime.utc_now(), -days, :day), nil}}

  defp n_days_range(other),
    do: {:error, "invalid last_n_days #{inspect(other)} — expected a positive integer"}

  defp date_range(from_date, to_date) do
    with {:ok, from} <- parse_date(from_date, ~T[00:00:00]),
         {:ok, to} <- parse_date(to_date, ~T[23:59:59.999999]) do
      {:ok, {from, to}}
    end
  end

  defp parse_date(nil, _time), do: {:ok, nil}

  defp parse_date(value, time) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, DateTime.new!(date, time, "Etc/UTC")}
      {:error, _} -> {:error, "invalid date #{inspect(value)} — expected ISO 8601 (YYYY-MM-DD)"}
    end
  end

  defp parse_date(value, _time),
    do: {:error, "invalid date #{inspect(value)} — expected ISO 8601 (YYYY-MM-DD)"}

  # ── Fetching ─────────────────────────────────────────────────────────

  defp fetch_conversations(person_id, params, {from, to}) do
    conv_limit = params[:conversation_limit] || 10
    msg_limit = params[:messages_per_conversation] || 50

    list_opts =
      [person_id: person_id, limit: conv_limit]
      |> maybe_put(:query, params[:query])
      |> maybe_put(:from, from)
      |> maybe_put(:to, to)

    {conversations, {total_message_groups, current_window_message_groups}} =
      list_opts
      |> Conversations.list_conversations()
      |> Enum.map_reduce({[], []}, fn conv, {total_groups, current_window_groups} ->
        current_window_messages =
          conv
          |> Conversations.list_messages(limit: msg_limit)
          |> Enum.map(&message_output/1)

        total_messages = Conversations.list_messages(conv)

        conversation = %{
          id: conv.id,
          title: conv.title,
          updated_at: conv.updated_at,
          messages: current_window_messages
        }

        {conversation,
         {[total_messages | total_groups], [current_window_messages | current_window_groups]}}
      end)

    Logger.debug(
      "[History] fetched person_id=#{person_id} conversations=#{length(conversations)}"
    )

    metadata = %{
      total: summarize_messages(total_message_groups),
      current_window: summarize_messages(current_window_message_groups)
    }

    {:ok, %{conversations: conversations, metadata: metadata}}
  rescue
    # Expected data-layer failures must fail the action. Returning an empty
    # success would make "the person has no history" indistinguishable from
    # "history could not be fetched".
    error in [Ecto.QueryError, Ecto.Query.CastError, DBConnection.ConnectionError] ->
      Logger.warning(
        "[History] fetch failed person_id=#{inspect(person_id)} error=#{Exception.message(error)}"
      )

      {:error, Exception.message(error)}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp message_output(message) do
    %{role: message.role, content: message.content, inserted_at: message.inserted_at}
  end

  defp summarize_messages(message_groups) do
    messages = List.flatten(message_groups)

    %{
      messages: length(messages),
      user_messages: Enum.count(messages, &(&1.role == "user")),
      assistant_messages: Enum.count(messages, &(&1.role == "assistant")),
      first_message_date: first_message_date(messages),
      last_message_date: last_message_date(messages)
    }
  end

  defp first_message_date([]), do: nil

  defp first_message_date(messages),
    do: messages |> Enum.map(& &1.inserted_at) |> Enum.min(DateTime)

  defp last_message_date([]), do: nil

  defp last_message_date(messages),
    do: messages |> Enum.map(& &1.inserted_at) |> Enum.max(DateTime)
end
