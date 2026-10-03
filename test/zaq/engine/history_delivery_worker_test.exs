defmodule Zaq.Engine.HistoryDeliveryWorkerTest do
  use Zaq.DataCase, async: true
  use Oban.Testing, repo: Zaq.Repo

  alias Zaq.Engine.{HistoryDeliveryWorker, HistoryIngress}

  test "invalid references cannot create a recovery job" do
    delivery = %{
      confirmation: :confirmed,
      kind: :channel,
      provider: "mattermost",
      channel_config_id: 999_999,
      channel_id: "room",
      user_message_id: Ecto.UUID.generate(),
      assistant_message_id: Ecto.UUID.generate(),
      message_id: "provider-message",
      content: "answer"
    }

    assert {:error, :invalid_delivery_scope} = HistoryIngress.capture_confirmed(delivery)
    refute_enqueued(worker: HistoryDeliveryWorker)
    assert {:error, :invalid_delivery_scope} = HistoryIngress.capture_confirmed(delivery)
    refute_enqueued(worker: HistoryDeliveryWorker)
  end

  test "pending generation and failed delivery never schedule a history retry" do
    for confirmation <- [:pending, :failed, nil] do
      assert {:error, :unconfirmed_delivery} =
               HistoryIngress.capture_confirmed(%{confirmation: confirmation})
    end

    refute_enqueued(worker: HistoryDeliveryWorker)
  end
end
