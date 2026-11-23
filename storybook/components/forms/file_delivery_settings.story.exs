defmodule Storybook.Components.Forms.FileDeliverySettings do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.FileDeliverySettings.section/1
  def description, do: "Connection file limits and failure policy from shared capability metadata."

  def variations do
    [
      %Variation{
        id: :transport_limits,
        attributes: %{
          id: "file-delivery",
          name: "connection[file_delivery]",
          snapshot: %{
            resolved: %{file: :native},
            file_delivery: %{
              limits: %{
                max_attachment_bytes: %{value: 5_000_000, configurable: false},
                max_encoded_message_bytes: %{value: :unresolved, configurable: true, required: true},
                max_attachments_per_message: %{value: 10, configurable: true}
              }
            }
          },
          settings: %{"max_attachments_per_message" => 4, "send_on_file_failure" => false},
          errors: %{"max_encoded_message_mb" => "Required for file delivery"}
        }
      },
      %Variation{
        id: :unresolved_transport,
        attributes: %{
          id: "unresolved-files",
          name: "connection[file_delivery]",
          snapshot: %{resolved: %{file: :fallback}}
        }
      }
    ]
  end
end
