defmodule Zaq.Channels.EmailBridge.ImapConfigHelpersTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.EmailBridge.ImapConfigHelpers

  test "get/3 prefers top-level key over nested settings.imap" do
    config = %{
      "username" => "top@example.com",
      "settings" => %{"imap" => %{"username" => "nested@example.com"}}
    }

    assert ImapConfigHelpers.get(config, :username) == "top@example.com"
  end

  test "get/3 falls back to nested settings.imap for atom and string keys" do
    config = %{
      settings: %{imap: %{"ssl" => true, port: 993}}
    }

    assert ImapConfigHelpers.get(config, :port) == 993
    assert ImapConfigHelpers.get(config, "ssl") == true
  end

  test "normalize_mailbox_names/1 supports mailbox tuple/map/string forms" do
    mailboxes = [
      {"INBOX", "/", []},
      %{"mailbox" => "Support"},
      %{mailbox: "INBOX"},
      "  Archive  ",
      nil
    ]

    assert ImapConfigHelpers.normalize_mailbox_names(mailboxes) == ["Archive", "INBOX", "Support"]
  end

  test "selected_mailboxes_for_listener/1 preserves order and duplicates" do
    config = %{
      settings: %{
        imap: %{
          selected_mailboxes: [" INBOX ", "Support", "INBOX", ""]
        }
      }
    }

    assert ImapConfigHelpers.selected_mailboxes_for_listener(config) == [
             "INBOX",
             "Support",
             "INBOX"
           ]
  end

  test "normalize_bridge_config/1 normalizes selected mailboxes and token fallback" do
    config = %{
      provider: "email:imap",
      password: "secret",
      settings: %{
        imap: %{
          username: "imap-user",
          selected_mailboxes: ["Support", " INBOX ", "Support"]
        }
      }
    }

    normalized = ImapConfigHelpers.normalize_bridge_config(config)

    assert normalized.token == "secret"
    assert normalized.username == "imap-user"
    assert normalized.selected_mailboxes == ["INBOX", "Support"]
  end
end
