defmodule Zaq.Channels.IdentityScopeTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Channels.IdentityScope

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

    test "invalid endpoint without an attested connector id is unscoped" do
      assert IdentityScope.authority("mattermost", %{url: "ftp://chat.example.test/team"}) ==
               "unscoped"

      assert IdentityScope.authority("mattermost", %{id: nil, url: "ftp://chat.example.test/team"}) ==
               "unscoped"
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
