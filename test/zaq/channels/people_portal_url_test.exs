defmodule Zaq.Channels.PeoplePortalUrlTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.PeoplePortalUrl
  alias Zaq.Event

  defmodule EngineRouter do
    def dispatch(%Event{} = event) do
      send(self(), {:global_base_url_event, event})
      %{event | response: Process.get(:global_base_url_response)}
    end
  end

  test "builds the fixed credentials destination from the configured global base URL" do
    Process.put(:global_base_url_response, "https://zaq.example.test/prefix/")
    on_exit(fn -> Process.delete(:global_base_url_response) end)

    assert PeoplePortalUrl.credentials(node_router_module: EngineRouter) ==
             "https://zaq.example.test/prefix/people/credentials"

    assert_received {:global_base_url_event, event}
    assert event.request == %{}
    assert event.next_hop.destination == :engine
    assert event.opts[:action] == :system_config_get_global_base_url
    refute Keyword.has_key?(event.opts, :confidential)
  end

  test "returns nil for missing, unavailable, failed, or malformed Engine responses" do
    on_exit(fn -> Process.delete(:global_base_url_response) end)

    for response <- [nil, {:error, {:service_unavailable, :engine}}, {:error, :failed}, %{}] do
      Process.put(:global_base_url_response, response)
      assert PeoplePortalUrl.credentials(node_router_module: EngineRouter) == nil
    end
  end

  test "rejects unsafe or ambiguous base URLs" do
    for base <- [
          nil,
          "",
          "/relative",
          "ftp://zaq.example.test",
          "https://user:password@zaq.example.test",
          "https://zaq.example.test/root?next=evil",
          "https://zaq.example.test/root#fragment",
          "https://zaq.example.test/../admin",
          "https://zaq.example.test/%2e%2e/admin",
          "https://zaq.example.test\\evil",
          "https://zaq.example.test/<script>"
        ] do
      assert PeoplePortalUrl.build(base) == nil
    end
  end

  property "normalizes trailing slashes while preserving a safe deployment prefix" do
    check all(
            segments <- list_of(string(:alphanumeric, min_length: 1), max_length: 4),
            trailing_slashes <- integer(0..5)
          ) do
      prefix = Enum.join(segments, "/")
      path = if prefix == "", do: "", else: "/#{prefix}"
      base = "https://zaq.example.test#{path}" <> String.duplicate("/", trailing_slashes)

      expected_path = if prefix == "", do: "", else: "/#{prefix}"

      assert PeoplePortalUrl.build(base) ==
               "https://zaq.example.test#{expected_path}/people/credentials"
    end
  end
end
