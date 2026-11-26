defmodule ZaqWeb.Components.FileDeliverySettingsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.FileDeliverySettings

  test "declared bounds and effective requirements drive all file controls" do
    definition = %{
      value: :unresolved,
      configurable: true,
      required: true,
      type: :integer,
      unit: :bytes,
      validation: %{greater_than: 10, less_than_or_equal_to: 1000}
    }

    snapshot = %{
      resolved: %{file: :native},
      file_delivery: %{limits: %{max_attachment_bytes: definition}}
    }

    html =
      render_component(&FileDeliverySettings.section/1,
        id: "typed",
        name: "files",
        snapshot: snapshot
      )

    assert html =~ ~s(min="0.000011")
    assert html =~ ~s(max="0.001")
    assert html =~ ~s(aria-required="true")
    assert html =~ "Required for file delivery"
    refute html =~ "Leave blank to use the transport limit"
    refute html =~ ~s( required=)

    for optional <- [
          put_in(snapshot, [:resolved, :file], :unsupported),
          put_in(snapshot, [:file_delivery, :limits, :max_attachment_bytes, :value], 500)
        ] do
      html =
        render_component(&FileDeliverySettings.section/1,
          id: "optional",
          name: "files",
          snapshot: optional
        )

      refute html =~ "Required for file delivery"
      assert html =~ "Optional override"
    end
  end

  test "failed lookup offers recovery while a successful unsupported snapshot stays empty" do
    html =
      render_component(&FileDeliverySettings.section/1,
        id: "failed",
        name: "files",
        snapshot: nil,
        unavailable: true
      )

    assert html =~ "Capabilities unavailable"
    assert html =~ ~s(phx-click="open_capabilities")
    assert html =~ "Retry capabilities"
    refute html =~ ~s(type="number")
    refute html =~ "send_on_file_failure"

    assert render_component(&FileDeliverySettings.section/1,
             id: "empty",
             name: "files",
             snapshot: %{}
           ) == ""
  end

  test "form params strip only known LiveView usage markers without creating omitted file settings" do
    files = %{
      "_unused_max_attachment_mb" => "",
      "max_attachment_mb" => "1.000001",
      "_unused_send_on_file_failure" => "",
      "send_on_file_failure" => "false"
    }

    for path <- [["settings", "file_delivery"], ["file_delivery"]] do
      params = Enum.reduce(Enum.reverse(path), files, fn key, value -> %{key => value} end)
      cleaned = FileDeliverySettings.form_params(params, path)

      assert get_in(cleaned, path) == %{
               "max_attachment_mb" => "1.000001",
               "send_on_file_failure" => "false"
             }

      assert FileDeliverySettings.form_params(%{"name" => "Draft"}, path) == %{"name" => "Draft"}
      malformed = put_in(params, path, "malformed")
      assert FileDeliverySettings.form_params(malformed, path) == malformed
      unknown = put_in(params, path, %{"unexpected" => "true"})
      assert FileDeliverySettings.form_params(unknown, path) == unknown
    end
  end

  test "embedded file controls retain fields while their container supplies the heading" do
    html =
      render_component(&FileDeliverySettings.section/1,
        id: "embedded-files",
        name: "files",
        snapshot: %{resolved: %{file: :native}},
        heading: false
      )

    refute html =~ "<h3"
    assert html =~ "Send message if files fail"
  end

  test "channel and SMTP forms share fixed, configurable, required and unresolved presentations" do
    snapshot = %{
      resolved: %{file: :fallback},
      file_delivery: %{
        limits: %{
          max_attachment_bytes: %{value: 5_000_000, configurable: false, required: false},
          max_attachment_bytes_per_message: %{
            value: 20_000_000,
            configurable: true,
            required: false
          },
          max_upload_request_bytes: %{value: 8_000_000, configurable: false, required: false},
          max_encoded_message_bytes: %{value: :unresolved, configurable: true, required: true},
          max_attachments_per_message: %{value: 10, configurable: true, required: false}
        }
      }
    }

    for name <- ["form[settings][file_delivery]", "email_config[file_delivery]"] do
      html =
        render_component(&FileDeliverySettings.section/1,
          id: "file-settings",
          name: name,
          snapshot: snapshot,
          settings: %{"max_encoded_message_bytes" => 1_000_001},
          errors: %{"max_encoded_message_mb" => "Enter a positive size"}
        )

      assert html =~ "File delivery"
      assert html =~ "5 MB"
      assert html =~ "8 MB"
      assert html =~ "Fixed transport limit"
      assert html =~ "Required for file delivery"
      assert html =~ "body, headers and encoded attachments"
      assert html =~ "Enter a positive size"
      assert html =~ "1.000001"
      assert html =~ name <> "[max_encoded_message_mb]"
      assert html =~ name <> "[max_attachment_total_mb]"
      refute html =~ name <> "[max_attachment_mb]"
    end
  end

  test "unavailable and unsupported capabilities do not produce editable limits" do
    for snapshot <- [
          nil,
          %{},
          %{resolved: %{file: :unsupported}},
          %{
            kind: :data_source,
            resolved: %{file: :native},
            file_delivery: %{
              limits: %{max_attachment_bytes: %{value: 1000, configurable: true}}
            }
          }
        ] do
      html =
        render_component(&FileDeliverySettings.section/1,
          id: "files",
          name: "files",
          snapshot: snapshot
        )

      refute html =~ "File delivery"
      refute html =~ "type=\"number\""
    end

    for support <- [:native, :fallback] do
      html =
        render_component(&FileDeliverySettings.section/1,
          id: "files",
          name: "files",
          snapshot: %{resolved: %{file: support}}
        )

      assert html =~ "Unresolved"
      assert html =~ "Send message if files fail"
      refute html =~ "type=\"number\""
    end
  end
end
