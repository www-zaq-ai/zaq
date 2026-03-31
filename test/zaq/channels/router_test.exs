defmodule Zaq.Channels.RouterTest do
  use Zaq.DataCase, async: false

  alias Zaq.Channels.Router
  alias Zaq.Engine.Messages.Outgoing

  defmodule StubBridge do
    def send_reply(%Outgoing{} = outgoing, connection_details) do
      send(self(), {:send_reply, outgoing, connection_details})
      :ok
    end
  end

  defmodule FailingBridge do
    def send_reply(_outgoing, _connection_details), do: {:error, :delivery_failed}
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    Application.put_env(:zaq, :channels, %{
      test_platform: %{bridge: StubBridge},
      failing_platform: %{bridge: FailingBridge},
      web: %{bridge: Zaq.Channels.WebBridge}
    })

    on_exit(fn ->
      if original_channels do
        Application.put_env(:zaq, :channels, original_channels)
      else
        Application.delete_env(:zaq, :channels)
      end
    end)

    :ok
  end

  describe "deliver/1" do
    test "routes to correct bridge and returns :ok on success" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        provider: :test_platform
      }

      assert :ok = Router.deliver(outgoing)
      assert_received {:send_reply, ^outgoing, _connection_details}
    end

    test "returns {:error, {:no_bridge, provider}} for unknown provider" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        provider: :unknown_provider
      }

      assert {:error, {:no_bridge, :unknown_provider}} = Router.deliver(outgoing)
    end

    test "returns error from bridge on delivery failure" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "chan-1",
        provider: :failing_platform
      }

      assert {:error, :delivery_failed} = Router.deliver(outgoing)
    end

    test "passes empty connection_details for :web provider" do
      outgoing = %Outgoing{
        body: "hello",
        channel_id: "session-xyz",
        provider: :web,
        metadata: %{session_id: "session-xyz", request_id: "req-1"}
      }

      # WebBridge.send_reply broadcasts to PubSub — just verify no crash and no DB lookup
      Phoenix.PubSub.subscribe(Zaq.PubSub, "chat:session-xyz")
      Router.deliver(outgoing)
      assert_received {:pipeline_result, "req-1", %Outgoing{}, nil}
    end
  end
end
