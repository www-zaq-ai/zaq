defmodule ZaqWeb.Components.DesignSystem.IngestionSourceSelector do
  @moduledoc """
  Source toggle row for the BO ingestion file browser chrome band.

  Data-source scopes share one `DesignSystem.Toggle` segmented control. Values are
  `source:<id>`; the LiveView handles navigation via `switch_source`.

  **Layout / tokens:** `.zaq-ingestion-chrome-block`, `.zaq-ingestion-meta-label` in
  `assets/css/styles.css`; toggle segments use `.zaq-toggle-*` in the same file.
  """

  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.Toggle

  attr :active_source_id, :string, required: true
  attr :sources, :list, default: []

  def source_selector(assigns) do
    assigns =
      assigns
      |> assign(:source_value, current_source_value(assigns))
      |> assign(:source_choices, source_choices(assigns))

    ~H"""
    <div class="zaq-ingestion-chrome-block">
      <p class="zaq-ingestion-meta-label zaq-text-caption">
        Sources
      </p>
      <Toggle.toggle
        value={@source_value}
        event="switch_source"
        value_param="source"
        choices={@source_choices}
      />
    </div>
    """
  end

  defp current_source_value(%{active_source_id: source_id}), do: "source:#{source_id}"

  defp source_choices(assigns) do
    Enum.map(assigns.sources, fn source ->
      %{
        value: "source:#{source.id}",
        label: source.label,
        title: source.label,
        provider: source.provider
      }
    end)
  end
end
