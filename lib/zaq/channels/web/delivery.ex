defmodule Zaq.Channels.Web.Delivery do
  @moduledoc """
  Trusted adapter delivery descriptor for semantic WebBridge responses.

  Adapters provide a validated server-resolved topic and map supported semantic
  response names to their expected wire event names. Browser payloads must never
  construct or override this descriptor.
  """

  alias Zaq.Channels.Web.Validation

  @semantic_events [
    :widget_initialized,
    :conversation_initialized,
    :conversation_created,
    :conversation_history,
    :typing,
    :message_create,
    :message_edit,
    :message_step,
    :message_complete,
    :message_failed,
    :status,
    :error
  ]

  @allowed_fields [:consumer, :topic, :protocol_version, :events, :channel_config_id]
  @enforce_keys [:consumer, :topic, :protocol_version, :events]
  defstruct @enforce_keys ++ [:channel_config_id]

  @type t :: %__MODULE__{
          consumer: :bo | :widget,
          topic: String.t(),
          protocol_version: pos_integer(),
          events: map(),
          channel_config_id: pos_integer() | nil
        }

  @doc "Builds a trusted adapter delivery descriptor."
  @spec new(map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) do
    with :ok <- Validation.reject_unknown_fields(attrs, @allowed_fields),
         {:ok, consumer} <- consumer(Validation.fetch(attrs, :consumer)),
         {:ok, topic} <-
           Validation.identifier(Validation.fetch(attrs, :topic), :topic, required: true),
         {:ok, protocol_version} <- protocol_version(Validation.fetch(attrs, :protocol_version)),
         {:ok, events} <- events(Validation.fetch(attrs, :events)),
         {:ok, channel_config_id} <-
           channel_config_id(Validation.fetch(attrs, :channel_config_id)) do
      {:ok,
       %__MODULE__{
         consumer: consumer,
         topic: topic,
         protocol_version: protocol_version,
         events: events,
         channel_config_id: channel_config_id
       }}
    end
  end

  def new(_attrs), do: {:error, {:invalid_field, :delivery}}

  @doc "Builds the legacy BO delivery descriptor used during migration."
  @spec bo(String.t()) :: t()
  def bo(topic) do
    {:ok, delivery} =
      new(%{
        consumer: :bo,
        topic: topic,
        protocol_version: 1,
        events: %{
          status: :status_update,
          message_edit: :status_update,
          message_complete: :pipeline_result,
          message_failed: :pipeline_result,
          error: :pipeline_result
        }
      })

    delivery
  end

  @doc "Returns the serializable, namespaced reference carried in routing context."
  @spec reference(t()) :: map()
  def reference(%__MODULE__{} = delivery) do
    %{
      "consumer" => Atom.to_string(delivery.consumer),
      "topic" => delivery.topic,
      "protocol_version" => delivery.protocol_version,
      "channel_config_id" => delivery.channel_config_id,
      "events" =>
        Map.new(delivery.events, fn {semantic, external} ->
          {Atom.to_string(semantic), external_name(external)}
        end)
    }
  end

  @doc "Rebuilds a validated descriptor from its routing-context reference."
  @spec from_reference(term()) :: {:ok, t()} | {:error, :invalid_delivery_descriptor}
  def from_reference(reference) when is_map(reference) do
    with {:ok, consumer} <- reference_consumer(Map.get(reference, "consumer")),
         {:ok, events} <- reference_events(Map.get(reference, "events")),
         {:ok, delivery} <-
           new(%{
             consumer: consumer,
             topic: Map.get(reference, "topic"),
             protocol_version: Map.get(reference, "protocol_version"),
             channel_config_id: Map.get(reference, "channel_config_id"),
             events: events
           }) do
      {:ok, delivery}
    else
      _ -> {:error, :invalid_delivery_descriptor}
    end
  end

  def from_reference(_reference), do: {:error, :invalid_delivery_descriptor}

  @doc "Resolves the adapter event name for a semantic response type."
  @spec event_name(t(), atom()) :: {:ok, atom() | String.t()} | {:error, :unsupported_event}
  def event_name(%__MODULE__{events: events}, semantic) do
    case Map.fetch(events, semantic) do
      {:ok, name} -> {:ok, normalize_external_name(name)}
      :error -> {:error, :unsupported_event}
    end
  end

  defp consumer(consumer) when consumer in [:bo, :widget], do: {:ok, consumer}
  defp consumer(_consumer), do: {:error, {:invalid_field, :consumer}}

  defp protocol_version(nil), do: {:ok, 1}
  defp protocol_version(1), do: {:ok, 1}
  defp protocol_version(_version), do: {:error, {:invalid_field, :protocol_version}}

  defp events(nil), do: {:ok, %{}}

  defp events(events) when is_map(events) do
    case Enum.find(Map.keys(events), &(&1 not in @semantic_events)) do
      nil -> validate_event_names(events)
      event -> {:error, {:invalid_event, event}}
    end
  end

  defp events(_events), do: {:error, {:invalid_field, :events}}

  defp validate_event_names(events) do
    if Enum.all?(events, fn {_semantic, name} -> valid_event_name?(name) end) do
      {:ok, events}
    else
      {:error, {:invalid_field, :events}}
    end
  end

  defp valid_event_name?(name) when is_atom(name), do: name not in [nil, true, false]

  defp valid_event_name?(name) when is_binary(name),
    do: String.trim(name) != "" and byte_size(name) <= 255

  defp valid_event_name?(_name), do: false

  defp channel_config_id(nil), do: {:ok, nil}
  defp channel_config_id(id) when is_integer(id) and id > 0, do: {:ok, id}
  defp channel_config_id(_id), do: {:error, {:invalid_field, :channel_config_id}}

  defp reference_consumer("bo"), do: {:ok, :bo}
  defp reference_consumer("widget"), do: {:ok, :widget}
  defp reference_consumer(_consumer), do: {:error, :invalid_consumer}

  defp reference_events(events) when is_map(events) do
    Enum.reduce_while(events, {:ok, %{}}, fn {semantic, external}, {:ok, acc} ->
      case semantic_event(semantic) do
        {:ok, semantic} -> {:cont, {:ok, Map.put(acc, semantic, external)}}
        :error -> {:halt, {:error, :invalid_event}}
      end
    end)
  end

  defp reference_events(_events), do: {:error, :invalid_events}

  for event <- @semantic_events do
    defp semantic_event(unquote(Atom.to_string(event))), do: {:ok, unquote(event)}
  end

  defp semantic_event(_event), do: :error

  defp external_name(name) when is_atom(name), do: Atom.to_string(name)
  defp external_name(name), do: name

  defp normalize_external_name("pipeline_result"), do: :pipeline_result
  defp normalize_external_name("status_update"), do: :status_update
  defp normalize_external_name(name), do: name
end
