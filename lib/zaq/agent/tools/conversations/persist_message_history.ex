defmodule Zaq.Agent.Tools.Conversations.PersistMessageHistory do
  @moduledoc """
  Persists one message into conversation history through the Engine boundary.

  The action accepts either an existing `%Zaq.Engine.Messages.Incoming{}` routing
  envelope or generic routing fields. It stores exactly one message, defaulting
  to role `"assistant"`, so workflows can persist assistant-initiated messages
  without fabricating a user turn.
  """

  use Zaq.Engine.Workflows.Action,
    name: "persist_message_history",
    description: "Persist one message into the correct conversation history.",
    schema: [
      incoming: [
        type: :any,
        required: false,
        doc: "Optional Incoming struct or map used for conversation routing."
      ],
      message: [
        type: :any,
        required: false,
        doc: "Optional message attributes map. Top-level message fields fill missing values."
      ],
      content: [type: :string, required: false, doc: "Message content."],
      role: [type: :string, required: false, doc: "Message role. Defaults to assistant."],
      channel_id: [type: :string, required: false, doc: "Destination/source channel id."],
      provider: [
        type: :any,
        required: false,
        doc: "Channel provider, e.g. email, mattermost, slack. Falls back to channel."
      ],
      channel: [type: :string, required: false, doc: "Delivery channel alias for provider."],
      author_id: [
        type: :string,
        required: false,
        doc: "Conversation grouping id for non-email channels."
      ],
      author_name: [type: :string, required: false, doc: "Optional author display name."],
      thread_id: [
        type: :string,
        required: false,
        doc: "Optional thread id for channel/topic grouping."
      ],
      message_id: [type: :string, required: false, doc: "Optional provider message id."],
      conversation_id: [
        type: :string,
        required: false,
        doc: "Existing conversation id to append to."
      ],
      channel_identifier: [type: :string, required: false, doc: "Delivery channel id alias."],
      subject: [type: :string, required: false, doc: "Optional subject used as metadata."],
      topic: [type: :string, required: false, doc: "Optional topic used as metadata."],
      sent_message: [type: :string, required: false, doc: "Message content alias."],
      notification_log_id: [
        type: :integer,
        required: false,
        doc: "Optional notification audit log id."
      ],
      person: [
        type: :any,
        required: false,
        doc: "Optional person payload for conversation ownership."
      ],
      person_id: [
        type: :integer,
        required: false,
        doc: "Optional person id for conversation ownership."
      ],
      metadata: [type: :any, required: false, doc: "Incoming/message metadata map."],
      model: [type: :string, required: false, doc: "Optional model name."],
      sources: [type: :any, required: false, doc: "Optional message sources."],
      trace: [type: :any, required: false, doc: "Optional message trace."],
      confidence_score: [type: :float, required: false, doc: "Optional confidence score."],
      latency_ms: [type: :integer, required: false, doc: "Optional latency in milliseconds."],
      prompt_tokens: [type: :integer, required: false, doc: "Optional prompt token count."],
      completion_tokens: [
        type: :integer,
        required: false,
        doc: "Optional completion token count."
      ],
      total_tokens: [type: :integer, required: false, doc: "Optional total token count."]
    ],
    output_schema: [
      persisted: [type: :boolean, required: true],
      conversation_id: [type: :string, required: true],
      message_id: [type: :string, required: true]
    ]

  alias Zaq.Engine.Messages.Incoming
  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl Jido.Action
  def run(params, context) when is_map(params) do
    with {:ok, incoming} <- build_incoming(params),
         {:ok, message} <- build_message(params) do
      node_router = Map.get(context, :node_router, NodeRouter)

      %{incoming: incoming, message: message}
      |> Event.new(:engine, opts: [action: :persist_message_history])
      |> node_router.dispatch()
      |> Map.get(:response)
      |> handle_response()
    end
  end

  defp build_incoming(params) do
    incoming = get(params, :incoming)
    conversation_id = get(params, :conversation_id)

    case incoming do
      %Incoming{} = incoming ->
        {:ok, put_conversation_id(incoming, conversation_id)}

      incoming_attrs when is_map(incoming_attrs) ->
        incoming_attrs
        |> string_keyed()
        |> put_if_blank("content", message_content(params))
        |> put_if_blank("channel_id", channel_id(params))
        |> put_if_blank("provider", provider(params))
        |> put_if_blank("author_id", author_id(params))
        |> put_if_blank("author_name", get(params, :author_name))
        |> put_if_blank("thread_id", get(params, :thread_id))
        |> put_if_blank("message_id", get(params, :message_id))
        |> put_if_blank("person", get(params, :person))
        |> put_if_blank("subject", get(params, :subject))
        |> put_if_blank("topic", get(params, :topic))
        |> put_if_blank("notification_log_id", get(params, :notification_log_id))
        |> put_metadata(get(params, :metadata), conversation_id)
        |> new_incoming()

      _ ->
        %{
          "content" => message_content(params),
          "channel_id" => channel_id(params),
          "provider" => provider(params),
          "author_id" => author_id(params),
          "author_name" => get(params, :author_name),
          "thread_id" => get(params, :thread_id),
          "message_id" => get(params, :message_id),
          "person" => get(params, :person),
          "subject" => get(params, :subject),
          "topic" => get(params, :topic),
          "notification_log_id" => get(params, :notification_log_id)
        }
        |> put_metadata(get(params, :metadata), conversation_id)
        |> new_incoming()
    end
  end

  defp new_incoming(attrs) do
    with :ok <- validate_routing_attrs(attrs) do
      {:ok, Incoming.new(attrs)}
    end
  end

  defp validate_routing_attrs(attrs) do
    cond do
      blank?(Map.get(attrs, "content")) ->
        {:error, "message content is required"}

      blank?(Map.get(attrs, "provider")) ->
        {:error, "provider or channel is required"}

      blank?(Map.get(attrs, "channel_id")) ->
        {:error, "channel_id or channel_identifier is required"}

      true ->
        :ok
    end
  end

  defp build_message(params) do
    message = get(params, :message)
    message_attrs = if is_map(message), do: string_keyed(message), else: %{}

    attrs =
      %{
        "role" => get(params, :role) || "assistant",
        "content" => message_content(params),
        "model" => get(params, :model),
        "sources" => get(params, :sources),
        "metadata" => message_metadata(params),
        "person_id" => get(params, :person_id) || person_id(get(params, :person)),
        "trace" => get(params, :trace),
        "confidence_score" => get(params, :confidence_score),
        "latency_ms" => get(params, :latency_ms),
        "prompt_tokens" => get(params, :prompt_tokens),
        "completion_tokens" => get(params, :completion_tokens),
        "total_tokens" => get(params, :total_tokens)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()
      |> Map.merge(message_attrs)

    case Map.get(attrs, "content") do
      content when is_binary(content) and content != "" -> {:ok, attrs}
      _ -> {:error, "message content is required"}
    end
  end

  defp message_content(params) do
    message = get(params, :message)

    get(params, :content) ||
      get(params, :sent_message) ||
      if(is_binary(message), do: message) ||
      if is_map(message), do: Map.get(message, :content) || Map.get(message, "content")
  end

  defp provider(params), do: get(params, :provider) || get(params, :channel)

  defp channel_id(params), do: get(params, :channel_id) || get(params, :channel_identifier)

  defp author_id(params),
    do: get(params, :author_id) || get(params, :channel_identifier) || channel_id(params)

  defp person_id(%{id: id}) when is_integer(id), do: id
  defp person_id(%{"id" => id}) when is_integer(id), do: id
  defp person_id(_person), do: nil

  defp message_metadata(params) do
    params
    |> get(:metadata)
    |> case do
      metadata when is_map(metadata) -> string_keyed(metadata)
      _ -> %{}
    end
    |> maybe_put("subject", get(params, :subject))
    |> maybe_put("topic", get(params, :topic))
    |> maybe_put("notification_log_id", get(params, :notification_log_id))
  end

  defp put_conversation_id(%Incoming{} = incoming, nil), do: incoming

  defp put_conversation_id(%Incoming{} = incoming, conversation_id) do
    metadata = incoming.metadata || %{}
    %{incoming | metadata: Map.put(metadata, :conversation_id, conversation_id)}
  end

  defp put_metadata(attrs, metadata, conversation_id) do
    metadata = if is_map(metadata), do: string_keyed(metadata), else: %{}

    metadata =
      metadata
      |> maybe_put("subject", get(attrs, :subject))
      |> maybe_put("topic", get(attrs, :topic))
      |> maybe_put("notification_log_id", get(attrs, :notification_log_id))

    metadata =
      if conversation_id,
        do: Map.put(metadata, "conversation_id", conversation_id),
        else: metadata

    Map.put(attrs, "metadata", metadata)
  end

  defp get(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp put_if_blank(map, key, value) do
    if blank?(Map.get(map, key)), do: Map.put(map, key, value), else: map
  end

  defp maybe_put(map, _key, value) when value in [nil, ""], do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(value), do: is_nil(value)

  defp string_keyed(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp handle_response({:ok, %{conversation_id: conversation_id, message_id: message_id}}) do
    {:ok, %{persisted: true, conversation_id: conversation_id, message_id: message_id}}
  end

  defp handle_response({:error, reason}) when is_binary(reason), do: {:error, reason}
  defp handle_response({:error, reason}), do: {:error, inspect(reason)}
  defp handle_response(other), do: {:error, "persist_message_history_failed:#{inspect(other)}"}
end
