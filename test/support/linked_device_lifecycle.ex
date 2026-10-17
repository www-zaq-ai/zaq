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
