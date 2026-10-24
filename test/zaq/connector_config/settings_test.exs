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

  test "legacy malformed runtime policies fail closed without provider-specific logic" do
    assert Settings.jido_chat_room_reply_policy(%{settings: %{}}) == :default

    for settings <- [
          nil,
          "invalid",
          %{"jido_chat" => []},
          %{"jido_chat" => %{"room_reply_policy" => nil}},
          %{"jido_chat" => %{"room_reply_policy" => "all"}}
        ] do
      assert Settings.jido_chat_room_reply_policy(%{settings: settings}) == :mention_required
    end
  end

  test "defaults support atom and string providers with an empty fallback" do
    assert Settings.defaults("whatsapp") == Settings.defaults(:whatsapp)

    for provider <- ["telegram", :telegram, "unregistered-provider", nil] do
      assert Settings.defaults(provider) == %{}
    end
  end

  property "defaults fill missing keys idempotently while explicit nested values win" do
    check all(
            value <- one_of([integer(), boolean(), string(:alphanumeric), constant(nil)]),
            max_runs: 30
          ) do
      config = %{
        provider: "whatsapp",
        settings: %{"other" => value, "jido_chat" => %{"ingress" => %{"sync_history" => value}}}
      }

      effective = Settings.effective(config)

      assert effective == %{
               "other" => value,
               "jido_chat" => %{
                 "room_reply_policy" => "mention_required",
                 "ingress" => %{"sync_history" => value, "sync_full_history" => false}
               }
             }

      assert Settings.effective(%{config | settings: effective}) == effective

      assert Settings.preserve(%{config | settings: effective}, %{"other" => "edited"}) ==
               %{"other" => "edited", "jido_chat" => effective["jido_chat"]}
    end
  end
end
