defmodule ZaqWeb.Components.DesignSystem.LabelChips do
  @moduledoc "Selected category chips and the shared resource-editor entry point."
  use Phoenix.Component
  import ZaqWeb.Components.DesignSystem.Table, only: [table_badge: 1]

  attr :labels, :list, default: []
  attr :resource_id, :integer, required: true
  attr :resource_type, :string, default: "document"

  def label_chips(assigns) do
    assigns =
      assigns
      |> assign(:visible_labels, Enum.take(assigns.labels, 2))
      |> assign(:hidden_count, max(length(assigns.labels) - 2, 0))

    ~H"""
    <div
      class="zaq-layout-inline zaq-label-chips"
      data-label-resource={"#{@resource_type}:#{@resource_id}"}
    >
      <.table_badge
        :for={label <- @visible_labels}
        status={display_label(label)}
        tone={:neutral}
        class="zaq-label-chip"
      >
        <span class="truncate" title={display_label(label)}>{display_label(label)}</span>
        <button
          type="button"
          class="zaq-label-chip-remove"
          phx-click="remove_resource_label"
          phx-value-type={@resource_type}
          phx-value-id={@resource_id}
          phx-value-label-id={label.id}
          aria-label={"Remove #{label.name} label"}
          title={"Remove #{label.name} label"}
        >×</button>
      </.table_badge>
      <button
        :if={@hidden_count > 0}
        type="button"
        class="zaq-label-more zaq-text-body-sm"
        phx-click="open_label_editor"
        phx-value-type={@resource_type}
        phx-value-id={@resource_id}
        aria-label={"Show #{@hidden_count} more labels"}
        title="View all labels"
      >+{@hidden_count}</button>
      <button
        type="button"
        id={"edit-labels-#{@resource_type}-#{@resource_id}"}
        class="zaq-label-add zaq-text-body-sm"
        phx-click="open_label_editor"
        phx-value-type={@resource_type}
        phx-value-id={@resource_id}
        aria-label="Add label"
      >+ Add label</button>
    </div>
    """
  end

  defp display_label(%{name: name, value: value}) when is_binary(value) and value != "",
    do: "#{name}: #{value}"

  defp display_label(label), do: label.name
end
