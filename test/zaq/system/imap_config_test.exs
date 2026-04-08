defmodule Zaq.System.ImapConfigTest do
  use Zaq.DataCase, async: true

  alias Zaq.System.ImapConfig

  defp base_config, do: %ImapConfig{}

  describe "changeset/2" do
    test "valid when disabled with defaults" do
      changeset = ImapConfig.changeset(base_config(), %{enabled: false})

      assert changeset.valid?
    end

    test "requires url, username and password when enabled" do
      changeset = ImapConfig.changeset(base_config(), %{enabled: true})

      refute changeset.valid?

      assert %{url: _, username: _, password: _} = errors_on(changeset)
    end

    test "accepts enabled config with valid host and numeric boundaries" do
      attrs = %{
        enabled: true,
        url: "imap.example.com:993",
        username: "imap-user",
        password: "secret",
        selected_mailboxes: ["INBOX", "Support"],
        port: 65_535,
        ssl_depth: 0,
        poll_interval: 1,
        idle_timeout: 1
      }

      changeset = ImapConfig.changeset(base_config(), attrs)

      assert changeset.valid?
    end

    test "rejects invalid url format" do
      attrs = %{enabled: false, url: "imap://bad host"}
      changeset = ImapConfig.changeset(base_config(), attrs)

      refute changeset.valid?
      assert %{url: _} = errors_on(changeset)
    end

    test "rejects out-of-range numeric values" do
      attrs = %{
        enabled: false,
        port: 0,
        ssl_depth: -1,
        poll_interval: 0,
        idle_timeout: 0,
        selected_mailboxes: ["INBOX"]
      }

      changeset = ImapConfig.changeset(base_config(), attrs)

      refute changeset.valid?

      assert %{port: _, ssl_depth: _, poll_interval: _, idle_timeout: _} = errors_on(changeset)
    end

    test "rejects empty normalized selected_mailboxes" do
      changeset =
        ImapConfig.changeset(base_config(), %{
          enabled: false,
          selected_mailboxes: ["", "   "]
        })

      refute changeset.valid?
      assert %{selected_mailboxes: _} = errors_on(changeset)
    end
  end

  describe "normalize_mailboxes/1" do
    test "normalizes delimited mailbox strings" do
      assert ImapConfig.normalize_mailboxes(" INBOX,Support\nSupport; Sales ; ") == [
               "INBOX",
               "Support",
               "Sales"
             ]
    end

    test "normalizes list values and drops non-binaries" do
      assert ImapConfig.normalize_mailboxes([" INBOX ", :ignored, "", "Support", "Support"]) == [
               "INBOX",
               "Support"
             ]
    end

    test "returns empty list for unsupported input" do
      assert ImapConfig.normalize_mailboxes(nil) == []
      assert ImapConfig.normalize_mailboxes(%{}) == []
    end
  end
end
