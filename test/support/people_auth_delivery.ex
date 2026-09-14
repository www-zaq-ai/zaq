defmodule Zaq.TestSupport.PeopleAuthDelivery do
  @moduledoc "Transport-only mock setup for real People login/notification integration tests (async: false)."
  import ExUnit.Callbacks
  import Mox

  alias Zaq.Channels.{ChannelConfig, PeopleAuthDeliveryMock}

  def setup do
    previous = Application.get_env(:zaq, :channels)
    Application.put_env(:zaq, :channels, %{email: %{bridge: PeopleAuthDeliveryMock}})
    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    stub(PeopleAuthDeliveryMock, :outbound_conversation_key, fn _, _ -> nil end)

    {:ok, _} =
      ChannelConfig.upsert_by_provider("email:smtp", %{
        name: "Test delivery",
        kind: "retrieval",
        enabled: true,
        settings: %{"relay" => "test.invalid"}
      })

    :ok
  end
end
