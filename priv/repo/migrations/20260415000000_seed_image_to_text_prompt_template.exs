defmodule Zaq.Repo.Migrations.SeedImageToTextPromptTemplate do
  use Ecto.Migration

  @body """
  You are a document data extraction engine. Your job is to extract ALL information from this image as structured, searchable text.

  ## Output format

  Use the following sections, including only those that apply:

  **TEXT**
  Transcribe all visible text verbatim, preserving hierarchy (titles > headings > body). Include labels, legends, axis titles, footnotes, watermarks, and annotations.

  **TABLE**
  Reproduce each table in Markdown format. If a table spans the full image, include every row and column. Do not summarize or truncate.

  **CHART / GRAPH**
  State the chart type. List every data series with its values: "Series: [name] → [x1: y1, x2: y2, ...]". Include axis labels, units, and scale.

  **DIAGRAM / FLOW**
  Describe nodes and edges explicitly: "A → B (label)", "C ← D". Capture decision branches, conditions, and loop indicators.

  **KEY VALUES**
  List any standalone metrics, KPIs, or named values as: "Label: value unit".

  ## Rules
  - Never describe what the image "looks like" — only output extracted data
  - Never skip a number, label, or cell because it seems redundant
  - If text is partially obscured, mark it [unclear]
  - Output only the populated sections — no section headers for absent content
  - No introductory sentences, no closing remarks
  """

  def up do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    repo().insert_all(
      "prompt_templates",
      [
        %{
          slug: "image_to_text",
          name: "Image to Text",
          description:
            "System prompt sent to the vision model when extracting descriptions from images during PDF ingestion.",
          active: true,
          body: @body,
          inserted_at: now,
          updated_at: now
        }
      ],
      on_conflict: :nothing,
      conflict_target: [:slug]
    )
  end

  def down do
    execute("DELETE FROM prompt_templates WHERE slug = 'image_to_text'")
  end
end
