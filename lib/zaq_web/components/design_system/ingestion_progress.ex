defmodule ZaqWeb.Components.DesignSystem.IngestionProgress do
  @moduledoc """
  Renders persisted document ingestion progress without querying chunks.

  Language-specific and language-neutral indexing are separate segments;
  the unfilled track represents chunks not yet indexed or failed. ParadeDB's
  current default analyzer is language-neutral despite detected chunk languages.
  """

  use Phoenix.Component

  attr :summary, :map, default: %{}

  def ingestion_progress(assigns) do
    summary = assigns.summary || %{}
    total = Map.get(summary, "total_chunks_detected")

    assigns =
      if is_integer(total) and total > 0 do
        indexed = clamp(Map.get(summary, "total_chunks_indexed", 0), 0, total)
        simple = clamp(Map.get(summary, "total_chunks_simple_indexed", 0), 0, indexed)
        specific = indexed - simple
        unindexed = total - indexed

        assigns
        |> assign(:total, total)
        |> assign(:indexed, indexed)
        |> assign(:simple, simple)
        |> assign(:neutral_label, neutral_label(summary))
        |> assign(:specific, specific)
        |> assign(:unindexed, unindexed)
        |> assign(:specific_pct, percentage(specific, total))
        |> assign(:simple_pct, percentage(simple, total))
        |> assign(:unindexed_pct, percentage(unindexed, total))
        |> assign(:errors, Map.get(summary, "errors", []))
        |> assign(
          :error_count,
          Map.get(summary, "total_errors", length(Map.get(summary, "errors", [])))
        )
        |> assign(:languages, Map.get(summary, "detected_languages", []))
      else
        assign(assigns, :total, total)
      end

    ~H"""
    <div class="zaq-ingestion-progress zaq-text-caption">
      <%= if is_integer(@total) and @total > 0 do %>
        <div
          class="zaq-ingestion-progress__track"
          role="progressbar"
          aria-label="Document chunks indexed"
          aria-valuemin="0"
          aria-valuemax={@total}
          aria-valuenow={@indexed}
          aria-valuetext={"#{@specific} language-specific, #{@simple} #{@neutral_label}, #{@unindexed} unindexed out of #{@total}"}
        >
          <span
            class="zaq-ingestion-progress__specific"
            style={"width: #{@specific_pct}%"}
            aria-hidden="true"
          />
          <span
            class="zaq-ingestion-progress__simple"
            style={"width: #{@simple_pct}%"}
            aria-hidden="true"
          />
        </div>
        <p class="zaq-ingestion-progress__counts">
          <span class="zaq-ingestion-progress__label--specific">{@specific} language-specific ({@specific_pct}%)</span>
          ·
          <span class="zaq-ingestion-progress__label--simple">{@simple} {@neutral_label} ({@simple_pct}%)</span>
          ·
          <span class="zaq-ingestion-progress__label--unindexed">{@unindexed} unindexed ({@unindexed_pct}%)</span>
        </p>
        <div
          :if={@languages != []}
          class="zaq-ingestion-progress__languages"
          aria-label="Detected languages"
        >
          <span :for={language <- @languages} class="zaq-ingestion-progress__language">
            {language_label(language)}
          </span>
        </div>
        <details :if={@errors != []} class="zaq-ingestion-progress__errors">
          <summary>{@error_count} indexing errors</summary>
          <ul>
            <li :for={error <- @errors}>
              Chunk {Map.get(error, "chunk_index")}: {Map.get(error, "message")}
            </li>
          </ul>
        </details>
      <% else %>
        <span>{if @total == 0, do: "No chunks", else: "Unavailable"}</span>
      <% end %>
    </div>
    """
  end

  defp clamp(number, low, high) when is_integer(number), do: number |> max(low) |> min(high)
  defp clamp(_, low, _high), do: low

  defp percentage(part, total), do: Float.round(part * 100 / total, 1)

  defp neutral_label(%{"index_backend" => "native"}), do: "simple fallback"
  defp neutral_label(%{"index_backend" => "parade_db"}), do: "default analyzer"
  defp neutral_label(_), do: "language-neutral indexing"

  defp language_label("simple"), do: "Undetermined"
  defp language_label(language) when is_binary(language), do: String.capitalize(language)
  defp language_label(_), do: "Undetermined"
end
