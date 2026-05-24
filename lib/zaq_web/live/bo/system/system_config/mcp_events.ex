defmodule ZaqWeb.Live.BO.System.SystemConfig.MCPEvents do
  @moduledoc """
  MCP-specific LiveView event orchestration helpers.
  """

  alias Zaq.Event
  alias Zaq.Utils.ParseUtils
  alias ZaqWeb.Live.BO.System.SystemConfig.MCPFeedback
  alias ZaqWeb.Live.BO.System.SystemConfig.MCPRows

  def apply_filters(socket, params) do
    socket
    |> Phoenix.Component.assign(:mcp_filter_name, Map.get(params, "mcp_filter_name", ""))
    |> Phoenix.Component.assign(:mcp_filter_type, Map.get(params, "mcp_filter_type", "all"))
    |> Phoenix.Component.assign(:mcp_filter_status, Map.get(params, "mcp_filter_status", "all"))
    |> Phoenix.Component.assign(:mcp_page, 1)
  end

  def change_page(socket, page) do
    Phoenix.Component.assign(
      socket,
      :mcp_page,
      ParseUtils.parse_int(page, socket.assigns.mcp_page)
    )
  end

  def new_endpoint(socket, load_form_fun) when is_function(load_form_fun, 1) do
    socket
    |> Phoenix.Component.assign(:mcp_endpoint_action, :new)
    |> Phoenix.Component.assign(:mcp_endpoint_id, nil)
    |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false)
    |> Phoenix.Component.assign(:mcp_endpoint_modal, true)
    |> load_form_fun.()
  end

  def edit_endpoint(socket, id, get_endpoint_fun, change_endpoint_fun) do
    endpoint = get_endpoint_fun.(id)

    socket
    |> Phoenix.Component.assign(:mcp_endpoint_action, :edit)
    |> Phoenix.Component.assign(:mcp_endpoint_id, endpoint.id)
    |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false)
    |> Phoenix.Component.assign(:mcp_endpoint_modal, true)
    |> Phoenix.Component.assign(
      :mcp_endpoint_form,
      Phoenix.Component.to_form(change_endpoint_fun.(endpoint), as: :mcp_endpoint)
    )
    |> Phoenix.Component.assign(:mcp_endpoint_rows, MCPRows.rows(endpoint))
  end

  def close_endpoint_modal(socket) do
    socket
    |> Phoenix.Component.assign(:mcp_endpoint_modal, false)
    |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false)
  end

  def open_delete_confirm(socket),
    do: Phoenix.Component.assign(socket, :mcp_endpoint_delete_confirm_modal, true)

  def cancel_delete_confirm(socket),
    do: Phoenix.Component.assign(socket, :mcp_endpoint_delete_confirm_modal, false)

  def enable_predefined(socket, predefined_id, predefined_catalog_fun, change_endpoint_fun)
      when is_function(predefined_catalog_fun, 0) and is_function(change_endpoint_fun, 1) do
    router = socket.assigns.node_router_module

    event =
      Event.new(%{action: :enable_predefined, predefined_id: predefined_id}, :agent,
        opts: [action: :mcp_endpoint_updated]
      )

    case router.dispatch(event).response do
      {:ok, %{endpoint: endpoint} = payload} ->
        socket = MCPFeedback.maybe_put_runtime_warnings(socket, payload)
        predefined = endpoint.predefined_id && predefined_catalog_fun.()[endpoint.predefined_id]

        socket =
          if is_map(predefined) and predefined[:editable] do
            socket
            |> Phoenix.Component.assign(:mcp_endpoint_action, :edit)
            |> Phoenix.Component.assign(:mcp_endpoint_id, endpoint.id)
            |> Phoenix.Component.assign(:mcp_endpoint_modal, true)
            |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false)
            |> Phoenix.Component.assign(
              :mcp_endpoint_form,
              Phoenix.Component.to_form(change_endpoint_fun.(endpoint), as: :mcp_endpoint)
            )
            |> Phoenix.Component.assign(:mcp_endpoint_rows, MCPRows.rows(endpoint))
          else
            socket
          end

        {:ok, socket}

      {:error, reason} ->
        {:error, inspect(reason)}

      other ->
        {:error, inspect(other)}
    end
  end

  def validate_endpoint(socket, params, endpoint_for_action_fun, change_endpoint_fun)
      when is_function(endpoint_for_action_fun, 2) and is_function(change_endpoint_fun, 2) do
    {rows, parsed} = MCPRows.build_endpoint_payload(params, socket.assigns.mcp_endpoint_rows)

    changeset =
      socket.assigns.mcp_endpoint_action
      |> endpoint_for_action_fun.(socket.assigns.mcp_endpoint_id)
      |> change_endpoint_fun.(parsed)
      |> Map.put(:action, :validate)

    socket
    |> Phoenix.Component.assign(
      :mcp_endpoint_form,
      Phoenix.Component.to_form(changeset, as: :mcp_endpoint)
    )
    |> Phoenix.Component.assign(:mcp_endpoint_rows, rows)
  end

  def add_row(socket, collection) do
    Phoenix.Component.assign(
      socket,
      :mcp_endpoint_rows,
      MCPRows.add_row(socket.assigns.mcp_endpoint_rows, collection)
    )
  end

  def remove_row(socket, collection, index) do
    Phoenix.Component.assign(
      socket,
      :mcp_endpoint_rows,
      MCPRows.remove_row(
        socket.assigns.mcp_endpoint_rows,
        collection,
        ParseUtils.parse_int(index, 0)
      )
    )
  end

  def save_endpoint(socket, params) do
    {rows, parsed} = MCPRows.build_endpoint_payload(params, socket.assigns.mcp_endpoint_rows)

    request =
      case socket.assigns.mcp_endpoint_action do
        :edit -> %{action: :update, id: socket.assigns.mcp_endpoint_id, attrs: parsed}
        _ -> %{action: :create, attrs: parsed}
      end

    router = socket.assigns.node_router_module
    event = Event.new(request, :agent, opts: [action: :mcp_endpoint_updated])

    case router.dispatch(event).response do
      {:ok, %{endpoint: endpoint} = payload} ->
        {:ok,
         socket
         |> Phoenix.Component.assign(:mcp_endpoint_modal, false)
         |> Phoenix.Component.assign(:mcp_endpoint_rows, rows)
         |> MCPFeedback.maybe_put_runtime_warnings(payload), endpoint.name}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:changeset,
         socket
         |> Phoenix.Component.assign(
           :mcp_endpoint_form,
           Phoenix.Component.to_form(Map.put(changeset, :action, :validate), as: :mcp_endpoint)
         )
         |> Phoenix.Component.assign(:mcp_endpoint_rows, rows)}

      {:error, reason} ->
        {:error, socket |> Phoenix.Component.assign(:mcp_endpoint_rows, rows), inspect(reason)}

      other ->
        {:error, socket |> Phoenix.Component.assign(:mcp_endpoint_rows, rows), inspect(other)}
    end
  end

  def delete_endpoint(socket) do
    router = socket.assigns.node_router_module

    event =
      Event.new(%{action: :delete, id: socket.assigns.mcp_endpoint_id}, :agent,
        opts: [action: :mcp_endpoint_updated]
      )

    case router.dispatch(event).response do
      {:ok, %{endpoint: endpoint} = payload} ->
        {:ok,
         socket
         |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false)
         |> Phoenix.Component.assign(:mcp_endpoint_modal, false)
         |> MCPFeedback.maybe_put_runtime_warnings(payload), endpoint.name}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:changeset,
         socket
         |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false)
         |> Phoenix.Component.assign(
           :mcp_endpoint_form,
           Phoenix.Component.to_form(Map.put(changeset, :action, :validate), as: :mcp_endpoint)
         )}

      {:error, reason} ->
        {:error, socket |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false),
         inspect(reason)}

      other ->
        {:error, socket |> Phoenix.Component.assign(:mcp_endpoint_delete_confirm_modal, false),
         inspect(other)}
    end
  end

  def test_endpoint(socket, id, mcp_module_fun) do
    endpoint_id = ParseUtils.parse_optional_int(id)
    router = socket.assigns.node_router_module

    event =
      Event.new(%{endpoint_id: endpoint_id}, :agent,
        opts: [
          action: :mcp_test_list_tools,
          mcp_module: mcp_module_fun.(),
          mcp_test_opts: [timeout: 5000]
        ]
      )

    case router.dispatch(event).response do
      {:ok, _payload} -> :ok
      {:error, reason} -> {:error, MCPFeedback.test_failure_message(reason)}
      other -> {:error, "MCP tools test returned: #{inspect(other)}"}
    end
  end
end
