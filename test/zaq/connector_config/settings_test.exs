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

  test "connector policy defaults on and preserves explicit boolean and form false" do
    assert Settings.attachment_failure_policy(%{}) == :continue

    for value <- [false, "false"] do
      assert Settings.attachment_failure_policy(%{settings: %{"send_on_file_failure" => value}}) ==
               :abort
    end

    for value <- [true, "true", nil] do
      assert Settings.attachment_failure_policy(%{settings: %{"send_on_file_failure" => value}}) ==
               :continue
    end
  end

  test "file failure boolean defaults on and preserves settings key precedence" do
    assert Settings.send_on_file_failure?(%{})
    assert Settings.send_on_file_failure?(%{settings: nil})

    refute Settings.send_on_file_failure?(%{
             settings: %{"send_on_file_failure" => false, send_on_file_failure: true}
           })

    refute Settings.send_on_file_failure?(%{
             :settings => %{send_on_file_failure: false},
             "settings" => %{"send_on_file_failure" => true}
           })
  end

  property "file failure boolean accepts atom and string keys with the same defaults" do
    check all(
            {value, expected} <-
              member_of([
                {false, false},
                {"false", false},
                {true, true},
                {"true", true},
                {nil, true}
              ]),
            settings_key <- member_of([:settings, "settings"]),
            flag_key <- member_of([:send_on_file_failure, "send_on_file_failure"])
          ) do
      assert Settings.send_on_file_failure?(%{settings_key => %{flag_key => value}}) === expected
    end
  end
end
