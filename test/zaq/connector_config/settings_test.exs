defmodule Zaq.ConnectorConfig.SettingsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ConnectorConfig.{ImapSettings, Settings, SmtpSettings}

  property "IMAP top-level values, including false and nil, override nested defaults" do
    check all(
            value <- one_of([integer(), string(:printable), boolean(), constant(nil)]),
            nested <- string(:printable)
          ) do
      for key <- [:username, "username"] do
        config = %{key => value, settings: %{"imap" => %{"username" => nested}}}
        assert ImapSettings.get(config, key, :missing) == value
      end
    end
  end

  test "shared helpers preserve atom/string lookup and malformed-input behavior" do
    assert ImapSettings.get(%{settings: %{imap: %{ssl: false}}}, :ssl, true) == false
    assert ImapSettings.get(nil, :username, :missing) == :missing
    assert SmtpSettings.map_get(%{relay: "smtp.example.com"}, "relay") == "smtp.example.com"

    assert SmtpSettings.map_get(%{"relay" => "explicit", relay: "fallback"}, "relay") ==
             "explicit"

    assert Settings.jido_chat_setting(%{settings: %{"jido_chat" => nil}}, "bot_name", "zaq") ==
             "zaq"

    assert Settings.imap_selected_mailboxes(%{
             settings: %{"imap" => %{"selected_mailboxes" => [nil, " INBOX ", ""]}}
           }) == ["INBOX"]
  end
end
