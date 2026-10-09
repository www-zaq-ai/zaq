defmodule Zaq.Channels.Web.Context do
  @moduledoc """
  Trusted execution context supplied by an authenticated web adapter.

  Transport payloads cannot construct this value. It keeps actor identity,
  explicit capabilities and BO-only routing inputs separate from Message and
  Command fields so nil identity never becomes implicit permission.
  """

  alias Zaq.Channels.Web.Delivery

  @capabilities [:skip_permissions]

  @enforce_keys [:consumer, :capabilities]
  defstruct @enforce_keys ++
              [
                :actor,
                :delivery,
                :selected_agent_id,
                :sender_id,
                :channel_config_id,
                content_filter: [],
                history: %{}
              ]

  @type t :: %__MODULE__{
          consumer: :bo | :widget,
          actor: map() | nil,
          capabilities: MapSet.t(atom()),
          delivery: Delivery.t() | nil,
          selected_agent_id: String.t() | nil,
          sender_id: String.t() | nil,
          channel_config_id: pos_integer() | nil,
          content_filter: [String.t()],
          history: map()
        }

  @doc "Builds trusted context separately from untrusted message or command fields."
  @spec new(map() | nil, keyword()) :: {:ok, t()} | {:error, term()}
  def new(actor, opts) when (is_map(actor) or is_nil(actor)) and is_list(opts) do
    consumer = Keyword.get(opts, :consumer)
    capabilities = Keyword.get(opts, :capabilities, [])
    delivery = Keyword.get(opts, :delivery)
    selected_agent_id = normalize_optional_string(Keyword.get(opts, :selected_agent_id))
    content_filter = Keyword.get(opts, :content_filter, [])
    history = Keyword.get(opts, :history, %{})
    sender_id = normalize_optional_string(Keyword.get(opts, :sender_id))
    channel_config_id = Keyword.get(opts, :channel_config_id)

    with :ok <- validate_consumer(consumer),
         {:ok, capabilities} <- validate_capabilities(capabilities),
         :ok <- validate_delivery(delivery, consumer),
         :ok <- validate_content_filter(content_filter),
         true <- is_map(history) || {:error, {:invalid_field, :history}},
         :ok <-
           validate_widget_options(
             consumer,
             capabilities,
             selected_agent_id,
             content_filter,
             history
           ),
         :ok <- validate_actor_capabilities(actor, capabilities),
         :ok <- validate_config_scope(channel_config_id, delivery) do
      {:ok,
       %__MODULE__{
         consumer: consumer,
         actor: actor,
         capabilities: capabilities,
         delivery: delivery,
         selected_agent_id: selected_agent_id,
         sender_id: sender_id,
         channel_config_id: channel_config_id,
         content_filter: content_filter,
         history: history
       }}
    end
  end

  def new(_actor, _opts), do: {:error, :unauthorized}

  @doc "Revalidates context at ingress, including values constructed without new/2."
  def validate(%__MODULE__{capabilities: %MapSet{} = capabilities} = context) do
    new(context.actor,
      consumer: context.consumer,
      capabilities: MapSet.to_list(capabilities),
      delivery: context.delivery,
      selected_agent_id: context.selected_agent_id,
      content_filter: context.content_filter,
      history: context.history,
      sender_id: context.sender_id,
      channel_config_id: context.channel_config_id
    )
  end

  def validate(_context), do: {:error, :invalid_web_context}

  defp validate_widget_options(:bo, _capabilities, _agent, _filters, _history), do: :ok

  defp validate_widget_options(:widget, capabilities, agent, filters, history) do
    if MapSet.size(capabilities) == 0 and is_nil(agent) and filters == [] and history == %{},
      do: :ok,
      else: {:error, :forbidden_widget_options}
  end

  defp validate_config_scope(nil, _delivery), do: :ok

  defp validate_config_scope(id, delivery) when is_integer(id) and id > 0 do
    if is_nil(delivery) or delivery.channel_config_id == id,
      do: :ok,
      else: {:error, {:invalid_field, :channel_config_id}}
  end

  defp validate_config_scope(_id, _delivery), do: {:error, {:invalid_field, :channel_config_id}}

  defp validate_consumer(consumer) when consumer in [:bo, :widget], do: :ok
  defp validate_consumer(_consumer), do: {:error, {:invalid_field, :consumer}}

  defp validate_capabilities(capabilities) when is_list(capabilities) do
    case Enum.find(capabilities, &(&1 not in @capabilities)) do
      nil -> {:ok, MapSet.new(capabilities)}
      capability -> {:error, {:invalid_capability, capability}}
    end
  end

  defp validate_capabilities(_capabilities), do: {:error, {:invalid_field, :capabilities}}

  defp validate_actor_capabilities(nil, capabilities) do
    if MapSet.size(capabilities) == 0, do: :ok, else: {:error, :unauthorized}
  end

  defp validate_actor_capabilities(_actor, _capabilities), do: :ok

  defp validate_delivery(nil, _consumer), do: :ok

  defp validate_delivery(%Delivery{consumer: consumer} = delivery, consumer) do
    case Delivery.new(Map.from_struct(delivery)) do
      {:ok, _delivery} -> :ok
      _ -> {:error, {:invalid_field, :delivery}}
    end
  end

  defp validate_delivery(%Delivery{}, _consumer), do: {:error, {:invalid_field, :delivery}}
  defp validate_delivery(_delivery, _consumer), do: {:error, {:invalid_field, :delivery}}

  defp validate_content_filter(filters) when is_list(filters) do
    if Enum.all?(filters, &(is_binary(&1) and String.trim(&1) != "")) do
      :ok
    else
      {:error, {:invalid_field, :content_filter}}
    end
  end

  defp validate_content_filter(_filters), do: {:error, {:invalid_field, :content_filter}}

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_optional_string(_value), do: nil
end
