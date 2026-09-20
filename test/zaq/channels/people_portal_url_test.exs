defmodule Zaq.Channels.PeoplePortalUrlTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.PeoplePortalUrl

  defmodule ConfiguredSystem do
    def get_global_base_url, do: "https://zaq.example.test/prefix/"
  end

  defmodule MissingSystem do
    def get_global_base_url, do: nil
  end

  test "builds the fixed credentials destination from the configured global base URL" do
    assert PeoplePortalUrl.credentials(system_module: ConfiguredSystem) ==
             "https://zaq.example.test/prefix/people/credentials"

    assert PeoplePortalUrl.credentials(system_module: MissingSystem) == nil
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
