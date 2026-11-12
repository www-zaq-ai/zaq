defmodule Zaq.Channels.CommunicationDeliveryObservationTest do
  use ExUnit.Case, async: true

  import Mox

  alias Zaq.Channels.CommunicationBridge
  alias Zaq.Channels.JidoChatBridge
  alias Zaq.Channels.PeopleAuthDeliveryMock, as: BridgeMock
  alias Zaq.Engine.Messages.Outgoing

  setup :verify_on_exit!

  test "the selected bridge interprets its own raw result" do
    outgoing = outgoing(:custom)
    response = {:error, {:custom_rejection, "PRIVATE_BODY"}}
    facts = %{outcome: :failed, reason: :rejected, provider_code: 42}

    expect(BridgeMock, :delivery_observation, fn ^outgoing, ^response -> facts end)
    assert CommunicationBridge.delivery_observation(BridgeMock, outgoing, response) == facts
  end

  test "Jido Chat uses its configured adapter rather than a generic reporter's provider switch" do
    for provider <- [:mattermost, "mattermost"] do
      assert CommunicationBridge.delivery_observation(
               JidoChatBridge,
               outgoing(provider),
               {:error, {403, "PRIVATE_BODY"}}
             ) ==
               %{outcome: :failed, reason: :rejected, provider_code: 403}
    end
  end

  test "an absent optional classifier uses only common communication failure facts" do
    for {response, facts} <- [
          {{:error, :timeout}, %{outcome: :unconfirmed, reason: :timeout}},
          {{:error, :missing_connection_details},
           %{outcome: :failed, reason: :missing_configuration}},
          {{:error, {:unsupported_provider, :custom}},
           %{outcome: :failed, reason: :unsupported_provider}},
          {{:error, {403, "PRIVATE_BODY"}}, %{outcome: :unconfirmed, reason: :unknown}},
          {{:error, :partial, "PRIVATE_BODY"}, %{outcome: :unconfirmed, reason: :unknown}}
        ] do
      assert CommunicationBridge.delivery_observation(__MODULE__, outgoing(), response) == facts
    end
  end

  for failure <- [:raise, :throw, :exit] do
    test "classification #{failure} cannot replace the delivery outcome" do
      expect(BridgeMock, :delivery_observation, fn _, _ ->
        case unquote(failure) do
          :raise -> raise "PRIVATE_BODY"
          :throw -> throw(:classification_unavailable)
          :exit -> exit(:classification_unavailable)
        end
      end)

      assert CommunicationBridge.delivery_observation(BridgeMock, outgoing(), {:error, :opaque}) ==
               %{outcome: :unconfirmed, reason: :unknown}
    end
  end

  test "successful sends do not invoke failure classification" do
    assert CommunicationBridge.delivery_observation(
             BridgeMock,
             outgoing(),
             {:ok, %{confirmation: :confirmed, message_id: "accepted"}}
           ) == nil
  end

  defp outgoing(provider \\ :test),
    do: %Outgoing{provider: provider, body: "answer", channel_id: "room"}
end
