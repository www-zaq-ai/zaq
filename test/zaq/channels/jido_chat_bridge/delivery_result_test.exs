defmodule Zaq.Channels.JidoChatBridge.DeliveryResultTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.JidoChatBridge.DeliveryResult

  describe "normalize_edit/2 unexpected responses" do
    test "rejects an unexpected adapter response and preserves it exactly" do
      assert DeliveryResult.normalize_edit(Jido.Chat.Mattermost.Adapter, :unexpected) ==
               {:error, {:unexpected_response, :unexpected}}
    end

    property "preserves every generated unexpected response" do
      unexpected_response =
        StreamData.one_of([
          StreamData.constant(nil),
          StreamData.boolean(),
          StreamData.integer(),
          StreamData.string(:alphanumeric, max_length: 8),
          StreamData.list_of(StreamData.integer(), max_length: 5),
          StreamData.map_of(
            StreamData.string(:alphanumeric, max_length: 8),
            StreamData.integer(),
            max_length: 5
          ),
          StreamData.map(StreamData.integer(), &{:unexpected, &1})
        ])

      check all(response <- unexpected_response, max_runs: 75) do
        assert DeliveryResult.normalize_edit(Jido.Chat.Mattermost.Adapter, response) ==
                 {:error, {:unexpected_response, response}}
      end
    end
  end
end
