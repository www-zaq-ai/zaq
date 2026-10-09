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

  test "missing durable confirmation is terminal and malformed jobs are cancelled" do
    missing_id = Ecto.UUID.generate()

    assert {:cancel, :missing_confirmation} =
             perform_job(HistoryDeliveryWorker, %{"message_id" => missing_id})

    refute_enqueued(worker: HistoryDeliveryWorker)

    for {job, result} <- [
          {%Oban.Job{args: %{}}, {:cancel, :unconfirmed_delivery}},
          {%Oban.Job{args: %{"message_id" => missing_id, "extra" => "legacy"}},
           {:cancel, :unconfirmed_delivery}},
          {%Oban.Job{args: %{"message_id" => nil}}, {:cancel, :missing_confirmation}}
        ] do
      assert ^result = HistoryDeliveryWorker.perform(job)
    end

    refute_enqueued(worker: HistoryDeliveryWorker)
  end
end
