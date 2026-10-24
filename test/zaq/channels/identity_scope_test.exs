defmodule Zaq.Channels.IdentityScopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.IdentityScope

  property "global user identities keep the same authority across connectors" do
    check all(
            platform <- member_of(["email", "telegram", "discord", "whatsapp"]),
            first_id <- integer(1..10_000),
            second_id <- integer(10_001..20_000),
            max_runs: 50
          ) do
      assert IdentityScope.authority(platform, %{id: first_id}) == "global"
      assert IdentityScope.authority(platform, %{id: second_id}) == "global"
    end
  end

  describe "Mattermost authority" do
    test "invalid endpoint schemes fall back to connector-local authority" do
      assert IdentityScope.authority("mattermost", %{id: 41, url: "ftp://chat.example.test/team"}) ==
               "connector:41"

      assert IdentityScope.authority("mattermost", %{id: 42, url: "ftp://chat.example.test/team"}) ==
               "connector:42"
    end

    test "hostless HTTP endpoint falls back to connector-local authority" do
      assert IdentityScope.authority("mattermost", %{id: 41, url: "https:/team"}) ==
               "connector:41"
    end

    test "invalid endpoint without an attested connector id is rejected" do
      for config <- [
            %{url: "ftp://chat.example.test/team"},
            %{id: nil, url: "ftp://chat.example.test/team"}
          ] do
        assert_raise ArgumentError, ~r/requires connector scope/, fn ->
          IdentityScope.authority("mattermost", config)
        end
      end
    end

    test "valid endpoint canonicalizes host and retains deployment path" do
      assert IdentityScope.authority("mattermost", %{
               id: 41,
               url: "https://CHAT.EXAMPLE.TEST/team/?token=secret#section"
             }) == "https://chat.example.test/team"
    end

    property "disallowed endpoint schemes always remain connector-local" do
      check all(
              id <- integer(1..10_000),
              scheme <- member_of(["ftp", "ws", "file"]),
              max_runs: 50
            ) do
        url = "#{scheme}://chat.example.test/team"
        assert IdentityScope.authority("mattermost", %{id: id, url: url}) == "connector:#{id}"
      end
    end
  end
end
