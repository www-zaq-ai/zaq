defmodule Zaq.TestSupport.LinkedDeviceConnectionStub do
  @moduledoc false
  def connect(config, opts) do
    parent = Keyword.fetch!(opts, :parent)

    case Agent.start(fn -> parent end, name: {:global, {__MODULE__, config.profile}}) do
      {:ok, pid} ->
        send(config.observer, {:connection, config.profile, pid, parent})
        {:ok, pid}

      {:error, _} ->
        {:error, :already_connected}
    end
  end

  def stop(pid, _opts) do
    if Process.alive?(pid), do: Agent.stop(pid)
    :ok
  end

  def deliver(
        pid,
        %Jido.Chat.EventEnvelope{
          event_type: :action,
          payload: %Jido.Chat.ActionEvent{metadata: %{category: :connection_lifecycle} = metadata}
        },
        _opts
      ),
      do: send(pid, {:lifecycle, metadata})

  def deliver(pid, payload, opts), do: send(pid, {:payload, payload, opts})
end

defmodule Zaq.TestSupport.LinkedDeviceFailingListener do
  @moduledoc false
  def start_link(_opts), do: {:error, :decoder_failed}
end

defmodule Zaq.TestSupport.LinkedDeviceLifecycle do
  @moduledoc false

  alias Jido.Chat.{ActionEvent, EventEnvelope}
  alias Jido.Chat.WhatsApp.Pairing

  def envelope(source, payload) do
    EventEnvelope.new(%{
      adapter_name: :whatsapp,
      event_type: :action,
      payload:
        ActionEvent.new(%{
          adapter: Jido.Chat.WhatsApp.Adapter,
          adapter_name: :whatsapp,
          action_id: "connection_update",
          metadata:
            Map.merge(payload, %{
              category: :connection_lifecycle,
              source: source,
              presentation: Pairing.presentation(payload)
            })
        })
    })
  end
end
