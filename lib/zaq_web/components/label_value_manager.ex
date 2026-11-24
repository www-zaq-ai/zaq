defmodule ZaqWeb.Components.LabelValueManager do
  @moduledoc "Paged label usage and explicit resource selection for versioned bulk value changes."
  use ZaqWeb, :live_component
  alias ZaqWeb.Components.DesignSystem.{Button, Input, LabelValue, Table}
  alias ZaqWeb.Live.BO.LabelEvents

  @impl true
  def update(assigns, socket) do
    if socket.assigns[:label] && socket.assigns.label.id == assigns.label.id do
      {:ok, assign(socket, assigns)}
    else
      {:ok,
       socket
       |> assign(assigns)
       |> assign(
         mode: :values,
         query: "",
         offset: 0,
         rows: [],
         more?: false,
         selected: MapSet.new(),
         value: nil,
         draft: nil,
         value_state: nil,
         confirming?: false,
         error: nil,
         notice: nil
       )
       |> load()}
    end
  end

  @impl true
  def handle_event("search_values", %{"query" => query}, socket),
    do: {:noreply, socket |> assign(query: String.slice(query, 0, 200), offset: 0) |> load()}

  def handle_event("show_value_resources", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {n, ""} when n >= 0 ->
        case Enum.at(socket.assigns.rows, n) do
          %{value: value, state: state} ->
            {:noreply,
             socket
             |> assign(
               mode: :resources,
               value: value,
               value_state: state,
               offset: 0,
               draft: value
             )
             |> load()}

          _ ->
            {:noreply, socket}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("show_values", _, socket),
    do: {:noreply, socket |> assign(mode: :values, offset: 0) |> load()}

  def handle_event("usage_page", %{"direction" => direction}, socket) do
    offset =
      case direction do
        "next" when socket.assigns.more? -> socket.assigns.offset + 50
        "previous" -> max(0, socket.assigns.offset - 50)
        _ -> socket.assigns.offset
      end

    {:noreply, socket |> assign(offset: offset) |> load()}
  end

  def handle_event("select_usage", %{"key" => key}, socket) do
    if Enum.any?(socket.assigns.rows, &(resource_key(&1) == key and &1.editable?)) do
      selected = socket.assigns.selected

      selected =
        if MapSet.member?(selected, key),
          do: MapSet.delete(selected, key),
          else: MapSet.put(selected, key)

      {:noreply, assign(socket, selected: selected, confirming?: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_all_usage", _, socket) do
    keys = editable_keys(socket.assigns.rows)
    selected = if socket.assigns.selected == keys, do: MapSet.new(), else: keys
    {:noreply, assign(socket, selected: selected, confirming?: false)}
  end

  def handle_event("review_value_update", %{"value" => value}, socket) do
    case LabelValue.parse_input(socket.assigns.label, value) do
      {:ok, native_value} ->
        {:noreply,
         assign(socket,
           draft: native_value,
           confirming?: MapSet.size(socket.assigns.selected) > 0,
           error: nil
         )}

      :error ->
        {:noreply, assign(socket, error: "Choose a value that matches this label's type.")}
    end
  end

  def handle_event("cancel_value_update", _, socket),
    do: {:noreply, assign(socket, confirming?: false, error: nil)}

  def handle_event("reload_usage", _, socket), do: {:noreply, load(socket)}

  def handle_event("confirm_value_update", _, %{assigns: %{confirming?: false}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm_value_update", _, socket) do
    resources =
      socket.assigns.rows
      |> Enum.filter(&MapSet.member?(socket.assigns.selected, resource_key(&1)))
      |> Enum.map(&Map.take(&1, [:type, :id, :expected_version]))

    case LabelEvents.call(socket.assigns.current_user, :update_label_values, %{
           label_id: socket.assigns.label.id,
           resources: resources,
           value: socket.assigns.draft
         }) do
      {:ok, count} ->
        send(self(), :label_values_updated)
        {:noreply, socket |> load() |> assign(notice: "Updated #{count} selected resources.")}

      {:error, reason} ->
        {:noreply, assign(socket, error: LabelEvents.error_message(reason))}
    end
  end

  defp load(socket) do
    %{label: label, mode: mode, offset: offset, current_user: user} = socket.assigns

    response =
      case mode do
        :values ->
          LabelEvents.call(user, :label_values, %{
            label_id: label.id,
            query: socket.assigns.query,
            offset: offset
          })

        :resources ->
          LabelEvents.call(user, :label_value_resources, %{
            label_id: label.id,
            value: socket.assigns.value,
            offset: offset
          })
      end

    case response do
      {:ok, rows} ->
        assign(socket,
          rows: Enum.take(rows, 50),
          more?: length(rows) > 50,
          selected: MapSet.new(),
          confirming?: false,
          error: nil,
          notice: nil
        )

      {:error, reason} ->
        assign(socket, error: LabelEvents.error_message(reason))
    end
  end

  defp resource_key(row), do: "#{row.type}-#{row.id}"

  defp editable_keys(rows),
    do: rows |> Enum.filter(& &1.editable?) |> Enum.map(&resource_key/1) |> MapSet.new()

  defp resource_title(row), do: row.title || row.source

  defp value_text(label, row) do
    case LabelValue.status_text(row) do
      "" -> LabelValue.format_value(label, row.value)
      status -> status
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} class="zaq-layout-stack">
      <p class="zaq-text-body-sm">
        Values belong to individual resources. Changes affect only the resources you select.
      </p>
      <div :if={@error} id="label-usage-error" role="alert" class="zaq-text-body-sm">
        {@error}
        <Button.button
          id="reload-label-usage"
          variant={:tertiary}
          phx-click="reload_usage"
          phx-target={@myself}
        >Reload resources</Button.button>
      </div>
      <p :if={@notice} role="status" class="zaq-text-body-sm">{@notice}</p>
      <%= if @mode == :values do %>
        <form
          id="label-values-search"
          phx-change="search_values"
          phx-submit="search_values"
          phx-target={@myself}
        >
          <Input.input
            type="search"
            name="query"
            value={@query}
            label="Search values"
            placeholder="Search existing values"
            phx-debounce="250"
            maxlength="200"
          />
        </form>
        <div class="overflow-x-auto">
          <table class="zaq-table zaq-border-default w-full table-fixed">
            <thead>
              <Table.table_head_row>
                <Table.table_cell element={:th}><Table.table_text label="Value" /></Table.table_cell>
                <Table.table_cell element={:th} width="w-24">
                  <Table.table_text label="Documents" />
                </Table.table_cell>
                <Table.table_cell element={:th} width="w-24">
                  <Table.table_text label="Chunks" />
                </Table.table_cell>
              </Table.table_head_row>
            </thead>
            <tbody>
              <Table.table_row :for={{row, index} <- Enum.with_index(@rows)}>
                <Table.table_cell>
                  <Button.button
                    variant={:ghost}
                    phx-click="show_value_resources"
                    phx-value-index={index}
                    phx-target={@myself}
                  >
                    <span class="truncate" title={value_text(@label, row)}>{value_text(@label, row)}</span>
                  </Button.button>
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_text label={to_string(row.documents)} />
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_text label={to_string(row.chunks)} />
                </Table.table_cell>
              </Table.table_row>
            </tbody>
          </table>
        </div>
        <p :if={@rows == []} class="zaq-text-body-sm">
          No matching values on resources you can read.
        </p>
      <% else %>
        <div class="zaq-layout-inline">
          <Button.button
            variant={:tertiary}
            phx-click="show_values"
            phx-target={@myself}
            icon="hero-arrow-left"
          >All values</Button.button>
          <span class="zaq-text-body-sm truncate">{@label.name}: {value_text(@label, %{
            value: @value,
            state: @value_state
          })}</span>
        </div>
        <%= if @confirming? do %>
          <div id="label-usage-confirm" class="zaq-card-default zaq-layout-stack">
            <p class="zaq-text-body">
              Set the value to “{LabelValue.format_value(@label, @draft)}” on {MapSet.size(@selected)} selected resource(s)?
            </p>
            <p class="zaq-text-body-sm">
              The label will remain assigned. Other resources will keep their values.
            </p>
            <div class="zaq-layout-inline">
              <Button.button
                id="cancel-label-value-update"
                variant={:tertiary}
                phx-click="cancel_value_update"
                phx-target={@myself}
              >Back</Button.button>
              <Button.button
                id="confirm-label-value-update"
                phx-click="confirm_value_update"
                phx-target={@myself}
              >Save changes</Button.button>
            </div>
          </div>
        <% else %>
          <form
            id="label-usage-edit"
            phx-submit="review_value_update"
            phx-target={@myself}
            class="zaq-layout-stack-tight"
          >
            <LabelValue.value_input
              id="bulk-label-value"
              definition={@label}
              name="value"
              value={@draft}
              label="New value"
              target={@myself}
            />
            <Button.button
              id="review-label-value-update"
              type="submit"
              disabled={MapSet.size(@selected) == 0}
            >Review changes ({MapSet.size(@selected)})</Button.button>
          </form>
        <% end %>
        <div class="overflow-x-auto">
          <table class="zaq-table zaq-border-default w-full table-fixed">
            <thead>
              <Table.table_head_row>
                <Table.table_cell element={:th} width="w-12">
                  <Table.table_checkbox
                    id="usage-select-all"
                    aria-label="Select editable resources on this page"
                    phx-click="select_all_usage"
                    phx-target={@myself}
                    disabled={@confirming? || MapSet.size(editable_keys(@rows)) == 0}
                    checked={MapSet.size(@selected) > 0 && @selected == editable_keys(@rows)}
                  />
                </Table.table_cell>
                <Table.table_cell element={:th}>
                  <Table.table_text label="Resource" />
                </Table.table_cell>
                <Table.table_cell element={:th} width="w-32">
                  <Table.table_text label="Type" />
                </Table.table_cell>
              </Table.table_head_row>
            </thead>
            <tbody>
              <Table.table_row
                :for={row <- @rows}
                variant={
                  if MapSet.member?(@selected, resource_key(row)), do: :selected, else: :default
                }
              >
                <Table.table_cell>
                  <Table.table_checkbox
                    id={"usage-select-#{resource_key(row)}"}
                    aria-label={"Select #{resource_title(row)}"}
                    disabled={!row.editable? || @confirming?}
                    checked={MapSet.member?(@selected, resource_key(row))}
                    phx-click="select_usage"
                    phx-value-key={resource_key(row)}
                    phx-target={@myself}
                  />
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_text label={resource_title(row)} class="truncate" />
                  <span :if={row.type == "chunk"} class="zaq-text-body-sm">Chunk {row.chunk_index + 1}</span>
                  <span :if={!row.editable?} class="zaq-text-body-sm">Read only</span>
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_text label={String.capitalize(row.type)} />
                </Table.table_cell>
              </Table.table_row>
            </tbody>
          </table>
        </div>
        <p :if={@rows == []} class="zaq-text-body-sm">No resources currently use this value.</p>
      <% end %>
      <div class="zaq-layout-inline">
        <Button.button
          variant={:tertiary}
          phx-click="usage_page"
          phx-value-direction="previous"
          phx-target={@myself}
          disabled={@offset == 0 || @confirming?}
        >Previous</Button.button>
        <Button.button
          variant={:tertiary}
          phx-click="usage_page"
          phx-value-direction="next"
          phx-target={@myself}
          disabled={!@more? || @confirming?}
        >Next</Button.button>
      </div>
    </div>
    """
  end
end
