defmodule Zaq.ConnectorConfig.SettingsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.ConnectorConfig.{ImapSettings, Settings, SmtpSettings}

  alias Zaq.ConnectorConfig.FileSettings

  describe "file settings" do
    test "declared numeric rules validate effective values for every shared consumer" do
      snapshot = %{
        resolved: %{file: :native},
        file_delivery: %{
          limits: %{
            max_attachment_bytes: %{
              value: :unresolved,
              configurable: true,
              required: true,
              type: :integer,
              unit: :bytes,
              validation: %{greater_than: 10, less_than_or_equal_to: 100}
            }
          }
        }
      }

      assert :ok = FileSettings.validate(%{"max_attachment_bytes" => 11}, snapshot)
      assert :ok = FileSettings.validate(%{"max_attachment_bytes" => 100}, snapshot)

      for value <- [10, 101, "11", 11.0, false, nil, " "] do
        assert {:error, %{"max_attachment_bytes" => _}} =
                 FileSettings.validate(%{"max_attachment_bytes" => value}, snapshot)
      end

      assert {:error, %{"max_attachment_bytes" => "Required for file delivery"}} =
               FileSettings.validate(%{}, snapshot)

      fixed = put_in(snapshot, [:file_delivery, :limits, :max_attachment_bytes, :value], 50)
      assert :ok = FileSettings.validate(%{}, fixed)
      unsupported = put_in(snapshot, [:resolved, :file], :unsupported)
      assert :ok = FileSettings.validate(%{}, unsupported)
      assert :ok = FileSettings.validate(%{"send_on_file_failure" => false}, unsupported)
    end

    property "declared numeric bounds cannot be exceeded even with an unresolved transport ceiling" do
      check all(ceiling <- integer(1..1_000_000), excess <- integer(1..1000)) do
        snapshot = %{
          resolved: %{file: :native},
          file_delivery: %{
            limits: %{
              max_attachment_bytes: %{
                value: :unresolved,
                configurable: true,
                required: false,
                validation: %{less_than_or_equal_to: ceiling}
              }
            }
          }
        }

        assert :ok = FileSettings.validate(%{"max_attachment_bytes" => ceiling}, snapshot)

        assert {:error, %{"max_attachment_bytes" => _}} =
                 FileSettings.validate(%{"max_attachment_bytes" => ceiling + excess}, snapshot)
      end
    end

    test "typed declarations survive normalization without granting file support" do
      definition = %{
        value: :unresolved,
        configurable: true,
        required: true,
        type: :integer,
        unit: :bytes,
        validation: %{greater_than: 0, less_than_or_equal_to: 5_000_000}
      }

      snapshot = %{file_delivery: %{limits: %{max_attachment_bytes: definition}}}
      assert FileSettings.metadata(snapshot).limits.max_attachment_bytes == definition
      assert FileSettings.limit(snapshot, :max_attachment_bytes) == definition
      refute FileSettings.supported?(snapshot, :file)

      for invalid <- [
            %{type: :string},
            %{unit: :count},
            %{validation: %{unknown_rule: 1}},
            %{validation: %{greater_than: "0"}},
            %{validation: [:greater_than]},
            %{validation: %{greater_than: fn -> 0 end}}
          ] do
        malformed =
          put_in(
            snapshot,
            [:file_delivery, :limits, :max_attachment_bytes],
            Map.merge(definition, invalid)
          )

        assert FileSettings.metadata(malformed) == nil
      end
    end

    property "normalizing declared numeric bounds is idempotent" do
      check all(ceiling <- integer(1..100_000_000)) do
        snapshot = %{
          file_delivery: %{
            limits: %{
              max_attachment_bytes: %{
                value: ceiling,
                configurable: true,
                required: false,
                type: :integer,
                unit: :bytes,
                validation: %{greater_than: 0, less_than_or_equal_to: ceiling}
              }
            }
          }
        }

        normalized = FileSettings.metadata(snapshot)
        assert normalized == FileSettings.metadata(%{file_delivery: normalized})
        assert normalized.limits.max_attachment_bytes.value == ceiling
      end
    end

    test "data-source capabilities cannot enable message file delivery" do
      for kind <- [:data_source, "data_source"] do
        snapshot = %{
          kind: kind,
          resolved: %{file: :native},
          file_delivery: %{limits: %{max_attachment_bytes: %{value: 1000, configurable: true}}}
        }

        refute FileSettings.visible?(snapshot)
        refute FileSettings.supported?(snapshot, :file)
        assert FileSettings.metadata(snapshot) == nil
        assert {:error, _} = FileSettings.validate(%{"send_on_file_failure" => true}, snapshot)
      end
    end

    test "decimal MB conversion is exact, including a single byte" do
      assert {:ok, settings} =
               FileSettings.normalize_form(%{
                 "max_attachment_mb" => "1.000001",
                 "max_encoded_message_mb" => "0.000001",
                 "max_attachments_per_message" => "3",
                 "send_on_file_failure" => "false"
               })

      assert settings == %{
               "max_attachment_bytes" => 1_000_001,
               "max_encoded_message_bytes" => 1,
               "max_attachments_per_message" => 3,
               "send_on_file_failure" => false
             }

      assert FileSettings.form_values(settings)["max_attachment_mb"] == "1.000001"
      assert FileSettings.form_values(settings)["send_on_file_failure"] == false
    end

    test "blank limits remove overrides and malformed values produce field errors" do
      assert {:ok, %{}} =
               FileSettings.normalize_form(%{
                 "max_attachment_mb" => " ",
                 "max_attachments_per_message" => ""
               })

      for value <- ["0", "-1", "1e3", "0.0000001", "1.1234567", "NaN", 1.5] do
        assert {:error, %{"max_attachment_mb" => _}} =
                 FileSettings.normalize_form(%{"max_attachment_mb" => value})
      end

      for value <- ["1.5", "0", "bad", false] do
        assert {:error, %{"max_attachments_per_message" => _}} =
                 FileSettings.normalize_form(%{"max_attachments_per_message" => value})
      end

      assert {:error, %{"send_on_file_failure" => _}} =
               FileSettings.normalize_form(%{"send_on_file_failure" => "sometimes"})
    end

    test "declared aggregate and upload constraints use the shared decimal MB conversion" do
      assert {:ok,
              %{
                "max_attachment_bytes_per_message" => 20_000_001,
                "max_upload_request_bytes" => 8_000_001
              }} =
               FileSettings.normalize_form(%{
                 "max_attachment_total_mb" => "20.000001",
                 "max_upload_request_mb" => "8.000001"
               })
    end

    property "every positive byte count survives decimal MB presentation and normalization" do
      check all(bytes <- integer(1..100_000_000_000)) do
        form = FileSettings.form_values(%{"max_attachment_bytes" => bytes})
        assert {:ok, %{"max_attachment_bytes" => ^bytes}} = FileSettings.normalize_form(form)
      end
    end
  end

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
