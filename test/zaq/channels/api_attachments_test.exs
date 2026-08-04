defmodule Zaq.Channels.ApiAttachmentsTest do
  # Covers the dispatch seam itself: that the two attachment actions resolve a real bridge
  # and reach it. The unit tests around them call the bridge directly, so nothing else
  # exercises the module resolution these clauses do.
  use ExUnit.Case, async: true

  alias Zaq.Channels.Api
  alias Zaq.Contracts.Record
  alias Zaq.Event

  defmodule StubBridgeResolver do
    @moduledoc false

    def bridge_for(provider) do
      send(self(), {:bridge_for, provider})
      Process.get(:bridge_for_result, Zaq.Channels.ApiAttachmentsTest.StubBridge)
    end
  end

  defmodule StubBridge do
    @moduledoc false

    def materialize_inbound_attachment(request) do
      send(self(), {:materialize, request})
      {:ok, %{record: %Record{id: "x", kind: :file, content: "aGk="}}}
    end
  end

  defmodule BridgeWithoutCallback do
    @moduledoc false
    def send_reply(_outgoing, _details), do: :ok
  end

  defmodule StubAttachments do
    @moduledoc false

    def persist(request) do
      send(self(), {:persist, request})
      {:ok, %{record: %Record{id: "42", kind: :file}}}
    end
  end

  defp event(request, action, opts) do
    request
    |> Event.new(:channels, opts: Keyword.put(opts, :action, action))
    |> Map.put(:opts, Keyword.put(opts, :action, action))
  end

  describe ":materialize_inbound_attachment" do
    test "resolves the provider's bridge and calls it" do
      event =
        event(
          %{file_ref: "telegram://file/abc", provider: "telegram"},
          :materialize_inbound_attachment,
          bridge_module: StubBridgeResolver
        )

      assert %Event{response: {:ok, %{record: %Record{}}}} =
               Api.handle_event(event, :materialize_inbound_attachment, %{})

      assert_received {:bridge_for, "telegram"}
      assert_received {:materialize, %{file_ref: "telegram://file/abc"}}
    end

    test "answers unsupported when the resolved bridge has no media callback" do
      Process.put(:bridge_for_result, BridgeWithoutCallback)

      event =
        event(
          %{file_ref: "x://y", provider: "mattermost"},
          :materialize_inbound_attachment,
          bridge_module: StubBridgeResolver
        )

      assert %Event{response: {:error, :unsupported}} =
               Api.handle_event(event, :materialize_inbound_attachment, %{})
    end

    test "answers no_bridge when the provider resolves to nothing" do
      Process.put(:bridge_for_result, nil)

      event =
        event(
          %{file_ref: "x://y", provider: "nope"},
          :materialize_inbound_attachment,
          bridge_module: StubBridgeResolver
        )

      assert %Event{response: {:error, {:no_bridge, "nope"}}} =
               Api.handle_event(event, :materialize_inbound_attachment, %{})
    end

    test "the default bridge module actually exports bridge_for/1" do
      # Regression: this clause defaulted to a module without `bridge_for/1`, which raised
      # at runtime and returned a 500 on the Telegram webhook.
      event =
        event(%{file_ref: "x://y", provider: "telegram"}, :materialize_inbound_attachment, [])

      assert %Event{response: response} =
               Api.handle_event(event, :materialize_inbound_attachment, %{})

      refute match?({:error, {:no_bridge, _}}, response)
    end
  end

  describe ":persist_inbound_attachment" do
    test "delegates to the attachments module" do
      event =
        event(
          %{record: %Record{id: "r", kind: :file}, provider: "telegram"},
          :persist_inbound_attachment,
          attachments_module: StubAttachments
        )

      assert %Event{response: {:ok, %{record: %Record{id: "42"}}}} =
               Api.handle_event(event, :persist_inbound_attachment, %{})

      assert_received {:persist, %{provider: "telegram"}}
    end
  end
end
