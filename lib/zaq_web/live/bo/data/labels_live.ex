defmodule ZaqWeb.Live.BO.Data.LabelsLive do
  @moduledoc "Label catalog following Teams management and shared BO form conventions."
  use ZaqWeb, :live_view

  alias ZaqWeb.Components.{BOLayout, BOModal}
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.Checkbox, as: DSCheckbox
  alias ZaqWeb.Components.DesignSystem.Input, as: DSInput
  alias ZaqWeb.Components.DesignSystem.LabelValue
  alias ZaqWeb.Components.DesignSystem.Table
  alias ZaqWeb.Live.BO.LabelEvents
  import ZaqWeb.Components.SearchableSelect, only: [searchable_select: 1]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_path: "/bo/labels",
       selected_label: nil,
       usage_label: nil,
       value_summaries: %{},
       form: nil,
       modal_error: nil,
       deletion: nil,
       selected_ids: MapSet.new(),
       labels_by_id: %{},
       label_count: 0,
       offset: 0,
       query: "",
       more?: false,
       manager?: socket.assigns.current_user.role.name in ["admin", "super_admin"]
     )
     |> load_labels()}
  end

  @impl true
  def handle_info(:label_values_updated, socket), do: {:noreply, load_labels(socket)}

  def handle_info(:addons_updated, socket), do: {:noreply, socket}

  @impl true
  def handle_event("manage_label_values", %{"id" => id}, socket),
    do: {:noreply, assign(socket, usage_label: Map.get(socket.assigns.labels_by_id, id))}

  def handle_event("close_label_usage", _, socket),
    do: {:noreply, assign(socket, usage_label: nil)}

  def handle_event("new_label", _, socket) do
    {:noreply,
     assign(socket,
       selected_label: nil,
       modal_error: nil,
       form: to_form(default_form(), as: :label)
     )}
  end

  def handle_event("edit_label", %{"id" => id}, socket) do
    case Map.get(socket.assigns.labels_by_id, id) do
      nil ->
        {:noreply, socket}

      label ->
        params = definition_form(label)

        {:noreply,
         assign(socket,
           selected_label: label,
           form: to_form(params, as: :label),
           modal_error: nil
         )}
    end
  end

  def handle_event("close_label_form", _, socket),
    do: {:noreply, assign(socket, form: nil, modal_error: nil)}

  def handle_event("search_labels", %{"query" => query}, socket) do
    {:noreply, socket |> assign(query: String.slice(query, 0, 200), offset: 0) |> load_labels()}
  end

  def handle_event("labels_page", %{"direction" => "next"}, socket) do
    {:noreply,
     if(socket.assigns.more?,
       do: socket |> assign(offset: socket.assigns.offset + 50) |> load_labels(),
       else: socket
     )}
  end

  def handle_event("labels_page", %{"direction" => "previous"}, socket) do
    {:noreply, socket |> assign(offset: max(socket.assigns.offset - 50, 0)) |> load_labels()}
  end

  def handle_event("validate_label", %{"label" => params}, socket) do
    # Validation uses only the cached form, never a read during typing.
    params = Map.merge(socket.assigns.form.params, params)
    {:noreply, assign(socket, form: to_form(params, as: :label), modal_error: nil)}
  end

  def handle_event(event, _, %{assigns: %{form: nil}} = socket)
      when event in ["add_label_option", "remove_label_option"],
      do: {:noreply, socket}

  def handle_event("add_label_option", _, socket) do
    params = socket.assigns.form.params
    options = option_rows(params) ++ [new_option()]

    {:noreply,
     assign(socket,
       form: to_form(Map.put(params, "options", indexed_options(options)), as: :label)
     )}
  end

  def handle_event("remove_label_option", %{"id" => id}, socket) do
    params = socket.assigns.form.params
    options = Enum.reject(option_rows(params), &(&1["id"] == id))

    {:noreply,
     assign(socket,
       form: to_form(Map.put(params, "options", indexed_options(options)), as: :label)
     )}
  end

  def handle_event("save_label", %{"label" => params}, socket) do
    params = Map.merge(socket.assigns.form.params, params)
    attrs = definition_attrs(params)

    attrs =
      case socket.assigns.selected_label do
        nil -> attrs
        label -> Map.merge(attrs, %{id: label.id, expected_version: label.lock_version})
      end

    case LabelEvents.call(socket.assigns.current_user, :save_label_definition, %{attrs: attrs}) do
      {:ok, _label} ->
        {:noreply,
         socket
         |> assign(form: nil, modal_error: nil)
         |> load_labels()
         |> put_flash(:info, "Label saved.")}

      {:error, %Ecto.Changeset{} = changeset} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, &ZaqWeb.CoreComponents.translate_error/1)

        {:noreply,
         assign(socket,
           form:
             to_form(params,
               as: :label,
               errors: Enum.map(errors, fn {k, v} -> {k, {Enum.join(v, ", "), []}} end)
             )
         )}

      {:error, reason} ->
        {:noreply, assign(socket, modal_error: LabelEvents.error_message(reason))}
    end
  end

  def handle_event("toggle_label_selection", %{"id" => id}, socket) do
    selected = socket.assigns.selected_ids

    if socket.assigns.manager? and Map.has_key?(socket.assigns.labels_by_id, id) do
      updated =
        if MapSet.member?(selected, id),
          do: MapSet.delete(selected, id),
          else: MapSet.put(selected, id)

      {:noreply, refresh_selection(socket, updated)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("select_all_labels", _, socket) do
    ids = MapSet.new(Map.keys(socket.assigns.labels_by_id))
    selected = if socket.assigns.selected_ids == ids, do: MapSet.new(), else: ids

    {:noreply, if(socket.assigns.manager?, do: refresh_selection(socket, selected), else: socket)}
  end

  def handle_event("request_bulk_delete", _, socket) do
    ids = Enum.map(socket.assigns.selected_ids, &String.to_integer/1)
    {:noreply, preview_deletion(socket, :bulk, ids)}
  end

  def handle_event("request_delete_label", %{"id" => id}, socket) do
    case Map.get(socket.assigns.labels_by_id, id) do
      nil -> {:noreply, socket}
      label -> {:noreply, preview_deletion(socket, :single, [label.id])}
    end
  end

  def handle_event(event, _, socket) when event in ["cancel_bulk_delete", "cancel_delete_label"],
    do: {:noreply, assign(socket, deletion: nil)}

  def handle_event("confirm_bulk_delete", _, socket),
    do: {:noreply, confirm_deletion(socket, :bulk)}

  def handle_event("confirm_delete_label", _, socket),
    do: {:noreply, confirm_deletion(socket, :single)}

  defp refresh_selection(socket, selected) do
    socket
    |> assign(selected_ids: selected)
    |> stream(:labels, Map.values(socket.assigns.labels_by_id))
  end

  # Both entry points keep one confirmation snapshot; kind preserves their
  # distinct dispatch contracts, messages and form-restoration behavior.
  defp preview_deletion(socket, kind, ids, message \\ nil)
  defp preview_deletion(socket, _kind, [], _message), do: socket

  defp preview_deletion(socket, kind, ids, message) do
    {action, request} =
      case kind do
        :single -> {:label_deletion_preview, %{id: hd(ids)}}
        :bulk -> {:labels_deletion_preview, %{ids: ids}}
      end

    case LabelEvents.call(socket.assigns.current_user, action, request) do
      {:ok, previews} ->
        assign(socket, deletion: %{kind: kind, previews: List.wrap(previews), error: message})

      {:error, :not_found} when kind == :bulk ->
        missing_bulk_label(socket)

      {:error, reason} ->
        put_flash(socket, :error, LabelEvents.error_message(reason))
    end
  end

  defp confirm_deletion(%{assigns: %{deletion: %{kind: kind} = deletion}} = socket, kind) do
    requests =
      Enum.map(deletion.previews, fn preview ->
        %{
          id: preview.id,
          expected_version: preview.expected_version,
          expected_usage: preview.usage
        }
      end)

    {action, request} =
      case kind do
        :single -> {:delete_label_definition, hd(requests)}
        :bulk -> {:delete_label_definitions, %{labels: requests}}
      end

    case LabelEvents.call(socket.assigns.current_user, action, request) do
      {:ok, deleted} -> complete_deletion(socket, kind, deleted)
      {:error, reason} -> deletion_error(socket, kind, reason)
    end
  end

  defp confirm_deletion(socket, _kind), do: socket

  defp complete_deletion(socket, kind, deleted) do
    {socket, message} =
      case kind do
        :single ->
          {assign(socket, form: nil, selected_label: nil, modal_error: nil), "Label deleted."}

        :bulk ->
          {socket, "#{length(deleted)} labels deleted."}
      end

    socket
    |> assign(deletion: nil, offset: 0)
    |> load_labels()
    |> put_flash(:info, message)
  end

  defp deletion_error(socket, :bulk, :not_found), do: missing_bulk_label(socket)

  defp deletion_error(socket, :single, {:usage_changed, updated}) do
    assign(socket,
      deletion: %{
        kind: :single,
        previews: [updated],
        error: "Label usage changed. Review the details and confirm again."
      }
    )
  end

  defp deletion_error(socket, :single, :stale) do
    preview_deletion(
      socket,
      :single,
      Enum.map(socket.assigns.deletion.previews, & &1.id),
      "The label changed. Review the details and confirm again."
    )
  end

  defp deletion_error(socket, :bulk, reason)
       when reason == :stale or elem(reason, 0) == :usage_changed do
    preview_deletion(
      socket,
      :bulk,
      Enum.map(socket.assigns.deletion.previews, & &1.id),
      "Labels or their usage changed. Review the details and confirm again."
    )
  end

  defp deletion_error(socket, _kind, reason),
    do:
      assign(socket,
        deletion: %{socket.assigns.deletion | error: LabelEvents.error_message(reason)}
      )

  defp missing_bulk_label(socket) do
    socket
    |> assign(deletion: nil)
    |> load_labels()
    |> put_flash(
      :error,
      "A selected label no longer exists. Review the list and select labels again."
    )
  end

  defp deletion_view(nil), do: %{delete_preview: nil, bulk_preview: nil, delete_error: nil}

  defp deletion_view(%{kind: :single, previews: [preview], error: error}),
    do: %{delete_preview: preview, bulk_preview: nil, delete_error: error}

  defp deletion_view(%{kind: :bulk, previews: previews, error: error}),
    do: %{delete_preview: nil, bulk_preview: previews, delete_error: error}

  defp load_labels(socket) do
    case LabelEvents.call(socket.assigns.current_user, :list_labels, %{
           offset: socket.assigns.offset,
           query: socket.assigns.query
         }) do
      {:ok, labels} ->
        rows = Enum.take(labels, 50)

        summaries =
          LabelEvents.call(socket.assigns.current_user, :label_value_summaries, %{
            ids: Enum.map(rows, & &1.id)
          })

        socket =
          case summaries do
            {:ok, values} ->
              assign(socket, value_summaries: values)

            {:error, reason} ->
              socket
              |> assign(value_summaries: %{})
              |> put_flash(:error, LabelEvents.error_message(reason))
          end

        socket
        |> assign(
          selected_ids: MapSet.new(),
          labels_by_id: Map.new(rows, &{to_string(&1.id), &1}),
          label_count: length(rows),
          more?: length(labels) > 50
        )
        |> stream(:labels, rows, reset: true)

      {:error, reason} ->
        socket
        |> stream(:labels, [], reset: true)
        |> put_flash(:error, LabelEvents.error_message(reason))
    end
  end

  defp default_form do
    %{
      "name" => "",
      "description" => "",
      "document" => true,
      "chunk" => true,
      "value_type" => "boolean",
      "assignment_type" => "manual",
      "threshold" => 80,
      "scale_min" => 0,
      "scale_max" => 10,
      "scale_increment" => 1,
      "options" => indexed_options([new_option()])
    }
  end

  defp definition_form(label) do
    Map.merge(default_form(), %{
      "name" => label.name,
      "description" => label.description,
      "document" => "document" in label.resources,
      "chunk" => "chunk" in label.resources,
      "value_type" => label.value_type,
      "assignment_type" => label.assignment_type,
      "threshold" => label.threshold,
      "scale_min" => Map.get(label.value_config, "min", 0),
      "scale_max" => Map.get(label.value_config, "max", 10),
      "scale_increment" => Map.get(label.value_config, "increment", 1),
      "options" => indexed_options(Map.get(label.value_config, "options", [new_option()]))
    })
  end

  defp definition_attrs(params) do
    config =
      case params["value_type"] do
        "scale" ->
          %{
            "min" => number_input(params["scale_min"]),
            "max" => number_input(params["scale_max"]),
            "increment" => number_input(params["scale_increment"])
          }

        "options" ->
          %{"options" => option_rows(params)}

        _ ->
          %{}
      end

    %{
      name: params["name"],
      description: params["description"],
      resources: Enum.filter(["document", "chunk"], &(params[&1] in [true, "true"])),
      value_type: params["value_type"],
      value_config: config,
      assignment_type: params["assignment_type"],
      threshold: params["threshold"]
    }
  end

  defp number_input(value) do
    case LabelValue.parse_input(%{value_type: "scale"}, value) do
      {:ok, number} -> number
      :error -> value
    end
  end

  defp new_option, do: %{"id" => Ecto.UUID.generate(), "label" => ""}

  defp indexed_options(options),
    do:
      options
      |> Enum.with_index()
      |> Map.new(fn {option, index} -> {to_string(index), option} end)

  defp option_rows(params) do
    params
    |> Map.get("options", %{})
    |> Enum.sort_by(fn {index, _} ->
      case Integer.parse(index) do
        {number, ""} -> number
        _ -> index
      end
    end)
    |> Enum.map(&elem(&1, 1))
  end

  defp definition_errors(form),
    do:
      Enum.map_join(form.errors, ". ", fn {_field, error} ->
        ZaqWeb.CoreComponents.translate_error(error)
      end)

  @impl true
  def render(assigns) do
    assigns = assign(assigns, deletion_view(assigns.deletion))

    ~H"""
    <BOLayout.bo_layout
      current_user={@current_user}
      flash={@flash}
      page_title="Labels"
      current_path={@current_path}
      features_version={@features_version}
    >
      <div class="zaq-layout-stack">
        <BOModal.modal_shell
          :if={@usage_label}
          id="label-value-usage-modal"
          cancel_event="close_label_usage"
          title={"Values for #{@usage_label.name}"}
          max_width_class="zaq-modal--width-2xl"
          panel_class="zaq-modal--form"
        >
          <.live_component
            module={ZaqWeb.Components.LabelValueManager}
            id="label-usage"
            label={@usage_label}
            current_user={@current_user}
          />
        </BOModal.modal_shell>
        <div class="zaq-layout-inline justify-between">
          <p class="zaq-text-body-sm">Organize documents and chunks with reusable categories.</p>
          <DSButton.button :if={@manager?} id="new-label" phx-click="new_label" icon="hero-plus">New label</DSButton.button>
        </div>
        <div class="zaq-layout-inline justify-between items-end flex-wrap">
          <form
            id="labels-search-form"
            phx-change="search_labels"
            phx-submit="search_labels"
            class="w-full sm:max-w-md"
          >
            <DSInput.input
              type="search"
              id="labels-search"
              name="query"
              value={@query}
              label="Search labels"
              placeholder="Search by name or description"
              maxlength="200"
              phx-debounce="250"
            />
          </form>
          <div class={if MapSet.size(@selected_ids) == 0, do: "hidden"}>
            <DSButton.button
              :if={@manager?}
              id="delete-selected-labels"
              variant={:tertiary}
              danger
              icon="hero-trash"
              disabled={MapSet.size(@selected_ids) == 0}
              phx-click="request_bulk_delete"
            >Delete ({MapSet.size(@selected_ids)})</DSButton.button>
          </div>
        </div>
        <p :if={@label_count == 0} id="labels-empty" class="zaq-text-body-sm">
          {if String.trim(@query) == "", do: "No labels yet.", else: "No labels match your search."}
        </p>
        <div class="overflow-x-auto">
          <table
            class="zaq-table zaq-border-default w-full table-fixed min-w-[700px]"
            id="labels-table"
          >
            <thead>
              <Table.table_head_row>
                <Table.table_cell :if={@manager?} element={:th} width="w-12">
                  <Table.table_checkbox
                    id="select-all-labels"
                    aria-label="Select all labels on this page"
                    phx-click="select_all_labels"
                    checked={@label_count > 0 && MapSet.size(@selected_ids) == @label_count}
                  />
                </Table.table_cell>
                <Table.table_cell element={:th} width="w-1/4">
                  <Table.table_text label="Name" tone={:tertiary} />
                </Table.table_cell>
                <Table.table_cell element={:th}>
                  <Table.table_text label="Description" tone={:tertiary} />
                </Table.table_cell>
                <Table.table_cell element={:th} width="w-40">
                  <Table.table_text label="Values / Resources" tone={:tertiary} />
                </Table.table_cell>
                <Table.table_cell element={:th} width="w-40">
                  <Table.table_text label="Resources" tone={:tertiary} />
                </Table.table_cell>
                <Table.table_cell element={:th} width="w-16">
                  <span class="sr-only">Actions</span>
                </Table.table_cell>
              </Table.table_head_row>
            </thead>
            <tbody id="labels" phx-update="stream">
              <Table.table_row
                :for={{dom_id, label} <- @streams.labels}
                id={dom_id}
                variant={
                  if MapSet.member?(@selected_ids, to_string(label.id)), do: :selected, else: :default
                }
                click={if @manager?, do: "edit_label"}
                click_values={%{id: label.id}}
              >
                <Table.table_cell :if={@manager?}>
                  <Table.table_checkbox
                    aria-label={"Select #{label.name}"}
                    phx-click="toggle_label_selection"
                    phx-value-id={label.id}
                    checked={MapSet.member?(@selected_ids, to_string(label.id))}
                  />
                </Table.table_cell>
                <Table.table_cell>
                  <button
                    :if={@manager?}
                    type="button"
                    class="zaq-focus-visible text-left w-full"
                    phx-click="edit_label"
                    phx-value-id={label.id}
                    aria-label={"Edit #{label.name}"}
                  >
                    <Table.table_text label={label.name} class="zaq-label-description" />
                  </button>
                  <Table.table_text :if={!@manager?} label={label.name} class="zaq-label-description" />
                  <span class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
                    {String.capitalize(label.value_type)} · {String.capitalize(label.assignment_type)}
                    <%= if label.assignment_type == "automatic" do %>
                      · {label.threshold}%
                    <% end %>
                  </span>
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_text
                    label={label.description}
                    tone={:secondary}
                    class="zaq-label-description"
                  />
                </Table.table_cell>
                <Table.table_cell>
                  <DSButton.button
                    id={"label-values-#{label.id}"}
                    variant={:ghost}
                    phx-click="manage_label_values"
                    phx-value-id={label.id}
                    aria-label={"Manage values for #{label.name}"}
                  >
                    <% summary = Map.get(@value_summaries, label.id, %{values: 0, resources: 0}) %>
                    <span
                      class="zaq-text-body-sm whitespace-nowrap"
                      title={"#{summary.values} values / #{summary.resources} resources"}
                    >
                      {summary.values} / {summary.resources}
                    </span>
                  </DSButton.button>
                </Table.table_cell>
                <Table.table_cell nowrap>
                  <Table.table_text
                    label={Enum.map_join(label.resources, ", ", &String.capitalize/1)}
                    tone={:tertiary}
                  />
                </Table.table_cell>
                <Table.table_cell>
                  <Table.table_actions :if={@manager?} reveal={:hover}>
                    <DSButton.button
                      variant={:tertiary}
                      danger
                      icon_only
                      icon="hero-trash"
                      aria-label={"Delete #{label.name}"}
                      title="Delete label"
                      phx-click="request_delete_label"
                      phx-value-id={label.id}
                    />
                  </Table.table_actions>
                </Table.table_cell>
              </Table.table_row>
            </tbody>
          </table>
        </div>
        <div class="zaq-layout-inline">
          <DSButton.button
            variant={:secondary}
            phx-click="labels_page"
            phx-value-direction="previous"
            disabled={@offset == 0}
          >Previous</DSButton.button>
          <DSButton.button
            variant={:secondary}
            phx-click="labels_page"
            phx-value-direction="next"
            disabled={!@more?}
          >Next</DSButton.button>
        </div>
      </div>
    </BOLayout.bo_layout>
    <BOModal.form_dialog
      :if={@form && is_nil(@delete_preview)}
      id="label-definition-modal"
      max_width_class="zaq-modal--width-xl"
      title={if @selected_label, do: "Edit label", else: "New label"}
      cancel_event="close_label_form"
    >
      <.form
        for={@form}
        id="label-definition-form"
        phx-change="validate_label"
        phx-submit="save_label"
        class="zaq-layout-stack"
      >
        <p
          :if={@modal_error}
          role="alert"
          class="zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-danger)"
        >
          {@modal_error}
        </p>
        <p
          :if={@form.errors != []}
          role="alert"
          class="zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-danger)"
        >
          {definition_errors(@form)}
        </p>
        <DSInput.input field={@form[:name]} label="Name" required maxlength="80" />
        <DSInput.input
          field={@form[:description]}
          type="textarea"
          label="Description"
          maxlength="4000"
          rows="3"
          hint="Describe what this label represents."
        />
        <.searchable_select
          id="label-value-type"
          name="label[value_type]"
          label="Value type"
          label_position="block"
          value={@form[:value_type].value}
          options={[{"Boolean", "boolean"}, {"Scale", "scale"}, {"Defined options", "options"}]}
          searchable={false}
        />
        <div :if={@form[:value_type].value == "scale"} class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <DSInput.input field={@form[:scale_min]} type="number" step="any" label="Minimum" required />
          <DSInput.input field={@form[:scale_max]} type="number" step="any" label="Maximum" required />
          <DSInput.input
            field={@form[:scale_increment]}
            type="number"
            step="any"
            label="Increment"
            required
          />
        </div>
        <fieldset :if={@form[:value_type].value == "options"} class="zaq-layout-stack-tight">
          <legend class="zaq-text-body-sm">Defined options</legend>
          <div
            :for={{option, index} <- Enum.with_index(option_rows(@form.params))}
            class="flex items-end gap-2"
          >
            <input type="hidden" name={"label[options][#{index}][id]"} value={option["id"]} />
            <DSInput.input
              id={"label-option-name-#{index}"}
              name={"label[options][#{index}][label]"}
              label={"Option #{index + 1}"}
              value={option["label"]}
              maxlength="200"
              required
            />
            <DSButton.button
              type="button"
              variant={:tertiary}
              icon="hero-trash"
              icon_only
              phx-click="remove_label_option"
              phx-value-id={option["id"]}
              aria-label={"Remove option #{index + 1}"}
            />
          </div>
          <DSButton.button
            type="button"
            variant={:tertiary}
            phx-click="add_label_option"
            id="add-label-option"
          >Add option</DSButton.button>
        </fieldset>
        <.searchable_select
          id="label-assignment-type"
          name="label[assignment_type]"
          label="Assignment type"
          label_position="block"
          value={@form[:assignment_type].value}
          options={[{"Manual", "manual"}, {"Automatic", "automatic"}]}
          searchable={false}
        />
        <DSInput.input
          field={@form[:threshold]}
          type="number"
          label="Confidence threshold (%)"
          min="0"
          max="100"
          step="1"
          required
        />
        <p :if={@form[:assignment_type].value == "automatic"} class="zaq-text-body-sm">
          Automatic assignments remain pending until evaluation is available.
        </p>
        <fieldset class="zaq-layout-stack">
          <legend class="zaq-text-body-sm mb-2" style="color: var(--zaq-text-color-body-default)">
            Apply this label to
          </legend>
          <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
            <div class="zaq-resource-label-choice zaq-layout-stack-tight">
              <DSCheckbox.checkbox field={@form[:document]} label="Documents" />
              <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
                Label the whole document.
              </p>
            </div>
            <div class="zaq-resource-label-choice zaq-layout-stack-tight">
              <DSCheckbox.checkbox field={@form[:chunk]} label="Chunks" />
              <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
                Label individual sections.
              </p>
            </div>
          </div>
        </fieldset>
      </.form>
      <:actions>
        <DSButton.button
          :if={@selected_label && @manager?}
          id="delete-label"
          variant={:tertiary}
          danger
          icon="hero-trash"
          class="mr-auto"
          phx-click="request_delete_label"
          phx-value-id={@selected_label.id}
        >Delete label</DSButton.button>
        <DSButton.button variant={:secondary} phx-click="close_label_form">Cancel</DSButton.button>
        <DSButton.button type="submit" form="label-definition-form" id="save-label">Save</DSButton.button>
      </:actions>
    </BOModal.form_dialog>
    <BOModal.confirm_dialog
      :if={@delete_preview}
      id="delete-label-confirmation"
      title={"Delete “#{@delete_preview.name}”?"}
      message={
        if @delete_preview.usage.documents == 0 && @delete_preview.usage.chunks == 0,
          do: "This label is not assigned to any documents or chunks. Delete it permanently?",
          else: "This label will be permanently deleted. Documents and chunks will be kept."
      }
      max_width_class="zaq-modal--width-xl"
      cancel_event="cancel_delete_label"
      confirm_event="confirm_delete_label"
      confirm_button_id="confirm-delete-label"
      confirm_label="Delete label"
    >
      <:details>
        <.deletion_details id="delete-label-usage" labels={[@delete_preview]} error={@delete_error} />
      </:details>
    </BOModal.confirm_dialog>
    <BOModal.confirm_dialog
      :if={@bulk_preview}
      id="bulk-delete-labels-confirmation"
      title={"Delete #{length(@bulk_preview)} labels?"}
      message="These labels will be permanently deleted. Documents and chunks will be kept."
      max_width_class="zaq-modal--width-xl"
      cancel_event="cancel_bulk_delete"
      confirm_event="confirm_bulk_delete"
      confirm_button_id="confirm-bulk-delete-labels"
      confirm_label="Delete labels"
    >
      <:details>
        <.deletion_details id="bulk-delete-labels-usage" labels={@bulk_preview} error={@delete_error} />
      </:details>
    </BOModal.confirm_dialog>
    """
  end

  attr :id, :string, required: true
  attr :labels, :list, required: true
  attr :error, :string, default: nil

  defp deletion_details(assigns) do
    ~H"""
    <p
      :if={@error}
      role="alert"
      class="zaq-text-body-sm mb-4"
      style="color: var(--zaq-text-color-body-danger)"
    >
      {@error}
    </p>
    <Table.table id={@id} scrollable scroll_max={:sm}>
      <:head>
        <Table.table_head_row sticky_header>
          <Table.table_cell element={:th}>
            <Table.table_text label="Label" tone={:tertiary} />
          </Table.table_cell>
          <Table.table_cell element={:th} align={:right}>
            <Table.table_text label="Used by" tone={:tertiary} />
          </Table.table_cell>
        </Table.table_head_row>
      </:head>
      <:body>
        <Table.table_row :for={label <- @labels}>
          <Table.table_cell>
            <Table.table_text label={label.name} class="zaq-label-description" />
          </Table.table_cell>
          <Table.table_cell align={:right}>
            <%= if label.usage.documents == 0 && label.usage.chunks == 0 do %>
              <Table.table_text label="Not assigned" tone={:tertiary} />
            <% else %>
              <Table.table_text
                :if={label.usage.documents > 0}
                label={"#{label.usage.documents} document(s)"}
                tone={:secondary}
              />
              <Table.table_text
                :if={label.usage.chunks > 0}
                label={"#{label.usage.chunks} chunk(s)"}
                tone={:secondary}
              />
            <% end %>
          </Table.table_cell>
        </Table.table_row>
      </:body>
    </Table.table>
    <p class="zaq-text-body-sm mt-4" style="color: var(--zaq-text-color-body-tertiary)">
      Labels in use will also be removed from their assigned resources.
    </p>
    """
  end
end
