defmodule Zaq.Engine.HistoryDeliveryWorker do
  @moduledoc """
  Scheduling adapter for HistoryIngress's reference-only association recovery.
  Never sends messages or independently interprets delivery/audience evidence.
  """
  use Oban.Worker,
    queue: :default,
    max_attempts: 10,
    unique: [period: :infinity, states: [:available, :scheduled, :executing, :retryable]]

  alias Zaq.Engine.HistoryIngress

  @doc "Enqueues a canonical message reference in the confirmation transaction."
  def enqueue(id) when is_binary(id), do: %{message_id: id} |> new() |> Oban.insert()

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"message_id" => id} = args}) when map_size(args) == 1 do
    case HistoryIngress.associate_confirmation(id) do
      {:ok, _} -> :ok
      {:error, :missing_confirmation} -> {:cancel, :missing_confirmation}
      _ -> {:error, :history_association_unavailable}
    end
  rescue
    _ -> {:error, :history_association_unavailable}
  end

  def perform(_), do: {:cancel, :unconfirmed_delivery}
end
