defmodule Zaq.Channels.DeliveryConfirmation do
  @moduledoc """
  Reports normalized transport confirmations and unsuccessful outcomes to Engine.

  Transport success is preserved even if the downstream consumer is unavailable;
  reporting a receipt must never cause the accepted message to be resent.
  """

  alias Zaq.Engine.Messages.Outgoing
  alias Zaq.Event
  alias Zaq.NodeRouter

  @doc "Forwards a confirmed receipt and its original outgoing message to Engine."
  def record({:ok, %{confirmation: :confirmed} = receipt}, outgoing, opts) do
    router = Keyword.get(opts, :delivery_node_router, NodeRouter)

    outgoing = %{
      outgoing
      | metadata:
          Map.take(outgoing.metadata || %{}, [
            :user_message_id,
            :assistant_message_id,
            :persisted_assistant_message_id
          ])
    }

    event =
      Event.new(%{receipt: receipt, outgoing: outgoing}, :engine,
        opts: [action: :record_delivery_confirmation]
      )

    case router.dispatch(event) do
      %Event{response: {:ok, result}} ->
        {:ok, result}

      _ ->
        {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
    end
  rescue
    _ ->
      {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
  catch
    :exit, _ ->
      {:ok, Map.put(receipt, :confirmation_recording, :unavailable)}
  end

  def record({:error, _} = response, %Outgoing{} = outgoing, opts) do
    report_observation(response, outgoing, opts)
    response
  end

  def record({:error, _, _} = response, %Outgoing{} = outgoing, opts) do
    report_observation(response, outgoing, opts)
    response
  end

  def record(response, _outgoing, _opts), do: response

  defp report_observation(response, outgoing, opts) do
    metadata = outgoing.metadata || %{}

    answer_id =
      Map.get(metadata, :persisted_assistant_message_id, metadata[:assistant_message_id])

    if is_binary(answer_id) and is_binary(metadata[:user_message_id]) do
      {outcome, reason} = classify(response, outgoing.provider)

      observation = %{
        assistant_message_id: answer_id,
        user_message_id: metadata[:user_message_id],
        channel_config_id: Map.get(outgoing.routing_context || %{}, :channel_config_id),
        outcome: outcome,
        reason: reason
      }

      observation = put_provider_code(observation, response, outgoing.provider)

      router = Keyword.get(opts, :delivery_node_router, NodeRouter)

      Event.new(observation, :engine,
        opts: [action: :record_delivery_observation, confidential: true]
      )
      |> router.dispatch()
    end

    :ok
  rescue
    _ -> :ok
  catch
    _kind, _ -> :ok
  end

  defp classify({:error, :timeout}, _provider), do: {:unconfirmed, :timeout}

  defp classify({:error, {status, _body}}, provider)
       when provider in [:mattermost, "mattermost"] and
              status in [400, 401, 403, 404, 405, 413, 415, 422, 429],
       do: {:failed, :rejected}

  defp classify({:error, {:no_bridge, _}}, _provider), do: {:failed, :unsupported_provider}

  defp classify({:error, {:unsupported_provider, _}}, _provider),
    do: {:failed, :unsupported_provider}

  defp classify({:error, reason}, _provider)
       when reason in [:missing_connection_details, :invalid_connector_id, :connector_mismatch],
       do: {:failed, :missing_configuration}

  defp classify(_response, _provider), do: {:unconfirmed, :unknown}

  defp put_provider_code(observation, {:error, {status, _body}}, provider)
       when provider in [:mattermost, "mattermost"] and status in 100..599,
       do: Map.put(observation, :provider_code, status)

  defp put_provider_code(observation, _response, _provider), do: observation
end
