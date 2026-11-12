defmodule ZaqWeb.Components.DesignSystem.LabelEditor do
  @moduledoc "Share-modal style staged category selection using existing BO primitives."
  use Phoenix.Component
  import ZaqWeb.Components.DesignSystem.Button
  import ZaqWeb.Components.DesignSystem.Input
  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.LabelValue

  attr :labels, :list, required: true
  attr :selected, :any, required: true
  attr :values, :map, default: %{}
  attr :editable, :boolean, default: false
  attr :error, :string, default: nil
  attr :target, :any, default: nil
  attr :query, :string, default: ""

  def label_editor(assigns) do
    assigns =
      assigns
      |> assign(
        :active_labels,
        Enum.filter(assigns.labels, &MapSet.member?(assigns.selected, &1.id))
      )
      |> assign(
        :available_labels,
        Enum.filter(assigns.labels, fn label ->
          !MapSet.member?(assigns.selected, label.id) and
            String.contains?(
              String.downcase(label.name <> " " <> label.description),
              String.downcase(assigns.query)
            )
        end)
      )

    ~H"""
    <BOModal.form_dialog
      id="resource-label-modal"
      title="Edit labels"
      cancel_event="close_label_editor"
    >
      <div class="zaq-layout-stack" role="group" aria-label="Resource labels">
        <form
          id="search-resource-labels"
          phx-hook="LabelPicker"
          phx-change="search_labels"
          phx-submit="search_labels"
          phx-target={@target}
        >
          <.input
            type="search"
            id="resource-label-search"
            name="query"
            value={@query}
            label="Search labels"
            placeholder="Search by name or description"
            phx-debounce="150"
            disabled={!@editable}
          />
          <div
            :if={@editable && String.trim(@query) != ""}
            id="available-resource-labels"
            data-label-results
            class="zaq-label-search-results max-h-64 overflow-y-auto"
            aria-label="Matching labels"
          >
            <button
              :for={label <- @available_labels}
              id={"label-option-#{label.id}"}
              type="button"
              class="zaq-dropdown-menu-item zaq-dropdown-menu-item--padded w-full text-left"
              phx-click="toggle_label"
              phx-value-id={label.id}
              phx-target={@target}
              aria-label={"Add #{label.name} label"}
            >
              <span
                class="zaq-text-body zaq-label-description"
                style="color: var(--zaq-text-color-body-default)"
              >{label.name}</span>
              <span
                class="zaq-text-body-sm zaq-label-description"
                style="color: var(--zaq-text-color-body-tertiary)"
              >{label.description}</span>
              <span :if={LabelValue.status_text(label) != ""} class="zaq-text-body-sm">
                {LabelValue.status_text(label)}
              </span>
            </button>
            <p :if={@available_labels == []} class="zaq-text-body-sm p-4" role="status">
              No matching labels.
            </p>
          </div>
        </form>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
          Choose a label, then set its value.
        </p>
        <p :if={!@editable} class="zaq-text-body-sm">You have read-only access to these labels.</p>
        <p
          :if={@error}
          role="alert"
          class="zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-danger)"
        >
          {@error}
        </p>
        <p :if={@labels == []} class="zaq-text-body-sm">No labels support this resource type yet.</p>
        <div id="active-resource-labels" class="grid grid-cols-1 sm:grid-cols-2 gap-4">
          <.label_choice
            :for={label <- @active_labels}
            label={label}
            value={Map.get(@values, label.id, Map.get(label, :value))}
            editable={@editable}
            target={@target}
          />
        </div>
        <p
          :if={@active_labels == [] && @labels != []}
          class="zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          No labels assigned.
        </p>
      </div>
      <:actions>
        <.button :if={@error} variant={:secondary} phx-click="reload_labels" phx-target={@target}>Reload</.button>
        <.button variant={:secondary} phx-click="close_label_editor">Cancel</.button>
        <.button
          id="save-resource-labels"
          disabled={!@editable}
          phx-click="save_labels"
          phx-target={@target}
        >Save</.button>
      </:actions>
    </BOModal.form_dialog>
    """
  end

  defp label_choice(assigns) do
    ~H"""
    <div
      class="zaq-resource-label-choice zaq-layout-stack-tight min-w-0"
      data-selected="true"
    >
      <div class="flex items-start gap-2">
        <input
          type="checkbox"
          class="zaq-bo-checkbox zaq-focus-visible"
          id={"label-option-#{@label.id}"}
          name={"label-option-#{@label.id}"}
          checked
          disabled={!@editable}
          phx-click="toggle_label"
          phx-value-id={@label.id}
          phx-target={@target}
          aria-label={@label.name}
        />
        <span class="min-w-0">
          <span
            class="zaq-text-body zaq-label-description"
            style="color: var(--zaq-text-color-body-default)"
          >{@label.name}</span>
          <span
            class="zaq-text-body-sm zaq-label-description"
            style="color: var(--zaq-text-color-body-tertiary)"
          >{@label.description}</span>
          <span :if={LabelValue.status_text(@label) != ""} class="zaq-text-body-sm">
            {LabelValue.status_text(@label)}
          </span>
        </span>
      </div>
      <form
        id={"label-value-form-#{@label.id}"}
        phx-change="change_label_value"
        phx-submit="save_labels"
        phx-target={@target}
      >
        <input type="hidden" name="label_id" value={@label.id} />
        <LabelValue.value_input
          id={"label-value-#{@label.id}"}
          definition={@label}
          value={@value}
          label={"Value for #{@label.name}"}
          editable={@editable}
          target={@target}
        />
      </form>
    </div>
    """
  end
end
