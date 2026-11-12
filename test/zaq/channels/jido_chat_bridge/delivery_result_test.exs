defmodule Zaq.Channels.JidoChatBridge.DeliveryResultTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.JidoChatBridge.DeliveryResult

  describe "delivery_observation/2" do
    test "only the Mattermost adapter's attested rejection statuses prove failure" do
      for code <- [400, 401, 403, 404, 405, 413, 415, 422, 429] do
        response = {:error, {code, %{"message" => "PRIVATE_PROVIDER_BODY"}}}

        assert DeliveryResult.delivery_observation(Jido.Chat.Mattermost.Adapter, response) ==
                 %{outcome: :failed, reason: :rejected, provider_code: code}

        assert DeliveryResult.delivery_observation(Jido.Chat.Telegram.Adapter, response) == nil
      end
    end

    test "Mattermost ambiguous HTTP outcomes retain bounded codes without bodies" do
      for code <- [408, 500, 502, 503, 504] do
        response = {:error, {code, "PRIVATE_PROVIDER_BODY"}}

        assert DeliveryResult.delivery_observation(Jido.Chat.Mattermost.Adapter, response) ==
                 %{outcome: :unconfirmed, reason: :unknown, provider_code: code}
      end
    end

    property "only HTTP-range integers are extracted as Mattermost provider codes" do
      check all(code <- integer(-1000..2000)) do
        result =
          DeliveryResult.delivery_observation(
            Jido.Chat.Mattermost.Adapter,
            {:error, {code, "private"}}
          )

        if code in 100..599 do
          assert result.provider_code == code
          refute Map.has_key?(result, :body)
        else
          assert result == nil
        end
      end
    end
  end

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
