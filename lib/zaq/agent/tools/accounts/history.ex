defmodule Zaq.Agent.Tools.Accounts.History do
  @moduledoc """
  Fetches recent conversation history for a person.

  Queries up to `conversation_limit` conversations for the given `person_id`,
  then up to `messages_per_conversation` messages per conversation, returning
  them as a flat list ordered chronologically within each conversation.

  Returns an empty list when `person_id` is nil or no conversations exist.

  ## Schema

  - `person_id`                — optional. Integer or string ID of the person.
  - `conversation_limit`       — optional (default: 10). Max conversations to fetch.
  - `messages_per_conversation`— optional (default: 50). Max messages per conversation.

  ## Example

      History.run(%{person_id: 42}, %{})
      # => {:ok, %{history: [%Message{...}, ...]}}

      History.run(%{person_id: 42, conversation_limit: 3, messages_per_conversation: 10}, %{})
      # => {:ok, %{history: [...]}}
  """

  use Jido.Action,
    name: "fetch_history",
    description: "Fetch recent conversation history for a person.",
    schema: [
      person_id: [
        type: :any,
        required: false,
        doc: "Person ID (integer or string). Returns empty history when nil."
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
      ]
    ],
    output_schema: [
      history: [
        type: :list,
        required: true,
        doc: "Flat list of messages across all conversations."
      ]
    ]

  use Zaq.Engine.Workflows.Action

  require Logger

  alias Zaq.Engine.Conversations

  @impl Jido.Action
  def run(%{person_id: person_id} = params, _ctx) when not is_nil(person_id) do
    conv_limit = params[:conversation_limit] || 10
    msg_limit = params[:messages_per_conversation] || 50

    history =
      [person_id: person_id, limit: conv_limit]
      |> Conversations.list_conversations()
      |> Enum.flat_map(fn conv ->
        conv
        |> Conversations.list_messages()
        |> Enum.take(msg_limit)
      end)

    Logger.debug(
      "[History] fetched person_id=#{person_id} conversations=#{div(length(history), max(msg_limit, 1))} messages=#{length(history)}"
    )

    {:ok, %{history: history}}
  rescue
    error ->
      Logger.warning(
        "[History] failed person_id=#{inspect(person_id)} error=#{Exception.message(error)}"
      )

      {:ok, %{history: []}}
  end

  def run(_params, _ctx), do: {:ok, %{history: []}}
end
