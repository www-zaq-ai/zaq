defmodule Storybook.Modals.FilePreviewModal do
  use PhoenixStorybook.Story, :component

  alias ZaqWeb.Storybook.FilePreviewFixtures, as: FP

  def function, do: &ZaqWeb.Components.FilePreviewModal.modal/1

  def description do
    """
    Full-screen file preview modal (`BOModal.modal_shell` + header + `FilePreview.panel/1`). \
    Same component as `/bo/ingestion` when opening a previewable file. Use the **Preview** tab and switch **variations** to see each payload kind.

    **LiveView:** `cancel_event` is sent on backdrop click, Escape, and the close button; in Storybook without a socket those clicks do nothing, but the UI matches production.
    """
    |> String.trim()
  end

  def variations do
    cancel = "storybook_close_preview"

    [
      %VariationGroup{
        id: :preview_kinds,
        description: "Preview map kinds (fixtures match FilePreviewData.load/2 shape)",
        variations: [
          %Variation{
            id: :markdown,
            description: "Markdown",
            attributes: %{
              id: "sb-file-preview-markdown",
              cancel_event: cancel,
              preview: FP.markdown()
            }
          },
          %Variation{
            id: :text,
            description: "Plain text",
            attributes: %{
              id: "sb-file-preview-text",
              cancel_event: cancel,
              preview: FP.text()
            }
          },
          %Variation{
            id: :image,
            description: "Image",
            attributes: %{
              id: "sb-file-preview-image",
              cancel_event: cancel,
              preview: FP.image()
            }
          },
          %Variation{
            id: :pdf,
            description: "PDF in iframe",
            attributes: %{
              id: "sb-file-preview-pdf",
              cancel_event: cancel,
              preview: FP.pdf()
            }
          },
          %Variation{
            id: :binary,
            description: "Binary / download",
            attributes: %{
              id: "sb-file-preview-binary",
              cancel_event: cancel,
              preview: FP.binary()
            }
          },
          %Variation{
            id: :not_found,
            description: "File not found",
            attributes: %{
              id: "sb-file-preview-not-found",
              cancel_event: cancel,
              preview: FP.not_found()
            }
          }
        ]
      }
    ]
  end
end
