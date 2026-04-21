defmodule ZaqWeb.Live.BO.AI.AgentsLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Components.SearchableSelect

  alias Ecto.Changeset
  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.Tools.Registry
  alias Zaq.System

  @impl true
  def mount(_params, _session, socket) do
    filters = %{
      "name" => "",
      "model" => "",
      "conversation_enabled" => "all",
      "active" => "all",
      "sovereign" => "all"
    }

    credentials = System.list_ai_provider_credentials()
    credentials_by_id = Map.new(credentials, &{&1.id, &1})
    tools = Registry.tools()

    socket =
      socket
      |> assign(:current_path, "/bo/agents")
      |> assign(:filters, filters)
      |> assign(:credentials, credentials)
      |> assign(:credentials_by_id, credentials_by_id)
      |> assign(:tools, tools)
      |> assign(:page, 1)
      |> assign(:per_page, 20)
      |> assign(:mode, :idle)
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_agent, nil)
      |> assign(:model_options, [])
      |> assign(:selected_model_supports_tools, nil)
      |> assign(:advanced_options_json, "{}")
      |> assign(:advanced_options_error, nil)
      |> assign(:form_notice, nil)
      |> assign(:tools_picker_open, false)
      |> assign(:tools_picker_value, "")
      |> refresh_agents()

    {:ok, assign_new_changeset(socket)}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    filters = normalize_filters(filters)

    {:noreply,
     socket
     |> assign(:filters, filters)
     |> assign(:page, 1)
     |> refresh_agents()}
  end

  def handle_event("new_agent", _params, socket) do
    {:noreply, open_new_form(socket)}
  end

  def handle_event("cancel_agent_form", _params, socket) do
    {:noreply, close_form(socket)}
  end

  def handle_event("open_tools_picker", _params, socket) do
    {:noreply, assign(socket, :tools_picker_open, true)}
  end

  def handle_event("close_tools_picker", _params, socket) do
    {:noreply, assign(socket, :tools_picker_open, false)}
  end

  def handle_event("add_tool_from_picker", %{"tool_key" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("add_tool_from_picker", %{"tool_key" => tool_key}, socket) do
    selected_keys = selected_tool_keys(socket)

    {:noreply,
     socket
     |> put_selected_tools([tool_key | selected_keys])
     |> assign(:tools_picker_value, "")}
  end

  def handle_event("remove_tool", %{"key" => tool_key}, socket) do
    selected_keys = selected_tool_keys(socket)
    next_keys = Enum.reject(selected_keys, &(&1 == tool_key))

    {:noreply, put_selected_tools(socket, next_keys)}
  end

  def handle_event("toggle_form_boolean", %{"field" => field}, socket)
      when field in ["conversation_enabled", "active"] do
    current =
      case field do
        "conversation_enabled" -> socket.assigns.form[:conversation_enabled].value
        "active" -> socket.assigns.form[:active].value
      end

    toggled = current not in [true, "true"]

    {:noreply,
     socket
     |> update_form_boolean(field, toggled)
     |> assign(:tools_picker_open, false)}
  end

  def handle_event("select_agent", %{"id" => id}, socket) do
    int_id = String.to_integer(id)

    agent =
      Enum.find(socket.assigns.agents, &(&1.id == int_id)) ||
        Agent.get_agent!(int_id)

    {:noreply,
     socket
     |> assign(:mode, :edit)
     |> assign(:selected_agent_id, agent.id)
     |> assign(:selected_agent, agent)
     |> assign(:model_options, model_options_for_credential(agent.credential_id, socket))
     |> assign(:advanced_options_json, pretty_json(agent.advanced_options || %{}))
     |> assign(:advanced_options_error, nil)
     |> assign(:form_notice, nil)
     |> assign(:tools_picker_open, false)
     |> assign(:tools_picker_value, "")
     |> assign_changeset(Agent.change_agent(agent))}
  end

  def handle_event("validate", %{"configured_agent" => attrs}, socket) do
    base = current_form_agent(socket)

    case parse_form_attrs(attrs) do
      {:ok, parsed_attrs} ->
        changeset =
          base
          |> Agent.change_agent(parsed_attrs)

        {:noreply,
         socket
         |> assign_changeset(changeset)
         |> assign(:model_options, model_options_from_attrs(parsed_attrs, socket))
         |> assign(:advanced_options_json, Map.get(attrs, "advanced_options_json", "{}"))
         |> assign(:advanced_options_error, nil)
         |> assign(:form_notice, nil)}

      {:error, _message, parsed_attrs} ->
        changeset =
          base
          |> Agent.change_agent(parsed_attrs)
          |> Map.put(:action, nil)

        {:noreply,
         socket
         |> assign_changeset(changeset)
         |> assign(:model_options, model_options_from_attrs(parsed_attrs, socket))
         |> assign(:advanced_options_json, Map.get(attrs, "advanced_options_json", "{}"))
         |> assign(:advanced_options_error, nil)
         |> assign(:form_notice, nil)}
    end
  end

  def handle_event("save", %{"configured_agent" => attrs}, socket) do
    case parse_form_attrs(attrs) do
      {:ok, parsed_attrs} ->
        save_agent(assign(socket, :form_notice, nil), parsed_attrs)

      {:error, message, parsed_attrs} ->
        base = current_form_agent(socket)

        changeset =
          base
          |> Agent.change_agent(parsed_attrs)
          |> Changeset.add_error(:advanced_options, message)
          |> Map.put(:action, save_action(socket))

        {:noreply,
         socket
         |> assign_changeset(changeset)
         |> assign(:model_options, model_options_from_attrs(parsed_attrs, socket))
         |> assign(:advanced_options_json, Map.get(attrs, "advanced_options_json", "{}"))
         |> assign(:advanced_options_error, message)
         |> assign(:form_notice, nil)}
    end
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    agent = Agent.get_agent!(id)

    case Agent.delete_agent(agent) do
      {:ok, _deleted} ->
        socket =
          socket
          |> put_flash(:info, "Agent deleted")
          |> refresh_agents()

        {:noreply, reset_form_after_delete(socket, String.to_integer(id))}

      {:error, %Changeset{} = changeset} ->
        message =
          changeset
          |> Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Map.get(:base, [])
          |> List.first()
          |> Kernel.||("Failed to delete agent")

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp save_agent(socket, attrs) do
    case socket.assigns.mode do
      :new ->
        case Agent.create_agent(attrs) do
          {:ok, agent} ->
            {:noreply,
             socket
             |> put_flash(:info, "Agent created")
             |> assign(:mode, :edit)
             |> assign(:selected_agent_id, agent.id)
             |> assign(:selected_agent, agent)
             |> assign(:advanced_options_error, nil)
             |> assign(:form_notice, nil)
             |> assign(:advanced_options_json, pretty_json(agent.advanced_options || %{}))
             |> assign_changeset(Agent.change_agent(agent))
             |> assign(:model_options, model_options_for_credential(agent.credential_id, socket))
             |> refresh_agents()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign_changeset(%{changeset | action: :insert})
             |> assign(:form_notice, nil)}
        end

      :edit ->
        agent = current_form_agent(socket)

        case Agent.update_agent(agent, attrs) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> assign(:selected_agent, updated)
             |> assign(:advanced_options_error, nil)
             |> assign(:form_notice, "Agent updated")
             |> assign(:advanced_options_json, pretty_json(updated.advanced_options || %{}))
             |> assign_changeset(Agent.change_agent(updated))
             |> assign(
               :model_options,
               model_options_for_credential(updated.credential_id, socket)
             )
             |> refresh_agents()}

          {:error, changeset} ->
            {:noreply,
             socket
             |> assign_changeset(%{changeset | action: :update})
             |> assign(:form_notice, nil)}
        end
    end
  end

  defp current_form_agent(socket) do
    case socket.assigns do
      %{mode: :edit, selected_agent: %ConfiguredAgent{} = agent} -> agent
      %{mode: :edit, selected_agent_id: id} when is_integer(id) -> Agent.get_agent!(id)
      _ -> %ConfiguredAgent{}
    end
  end

  defp refresh_agents(socket) do
    {agents, total} =
      Agent.filter_agents(socket.assigns.filters,
        page: socket.assigns.page,
        per_page: socket.assigns.per_page
      )

    selected_agent =
      case socket.assigns.selected_agent_id do
        id when is_integer(id) ->
          Enum.find(agents, &(&1.id == id)) || socket.assigns.selected_agent

        _ ->
          nil
      end

    socket
    |> assign(:agents, agents)
    |> assign(:total_agents, total)
    |> assign(:selected_agent, selected_agent)
  end

  defp assign_new_changeset(socket) do
    assign_changeset(socket, Agent.change_agent(%ConfiguredAgent{}))
  end

  defp assign_changeset(socket, %Changeset{} = changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:selected_model_supports_tools, selected_model_supports_tools(changeset, socket))
    |> assign(:form, to_form(changeset, as: :configured_agent))
  end

  defp reset_form_after_delete(socket, deleted_id) do
    if socket.assigns.selected_agent_id == deleted_id do
      close_form(socket)
    else
      socket
    end
  end

  defp open_new_form(socket) do
    socket
    |> assign(:mode, :new)
    |> assign(:selected_agent_id, nil)
    |> assign(:selected_agent, nil)
    |> assign(:model_options, [])
    |> assign(:advanced_options_json, "{}")
    |> assign(:advanced_options_error, nil)
    |> assign(:form_notice, nil)
    |> assign(:tools_picker_open, false)
    |> assign(:tools_picker_value, "")
    |> assign_new_changeset()
  end

  defp close_form(socket) do
    socket
    |> assign(:mode, :idle)
    |> assign(:selected_agent_id, nil)
    |> assign(:selected_agent, nil)
    |> assign(:model_options, [])
    |> assign(:advanced_options_json, "{}")
    |> assign(:advanced_options_error, nil)
    |> assign(:form_notice, nil)
    |> assign(:tools_picker_open, false)
    |> assign(:tools_picker_value, "")
    |> assign_new_changeset()
  end

  defp save_action(socket) do
    case socket.assigns.mode do
      :edit -> :update
      _ -> :insert
    end
  end

  defp selected_tool_keys(socket) do
    socket.assigns.form[:enabled_tool_keys].value || []
  end

  defp put_selected_tools(socket, keys) do
    deduped_keys = keys |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
    changeset = Changeset.put_change(socket.assigns.changeset, :enabled_tool_keys, deduped_keys)

    assign_changeset(socket, changeset)
  end

  defp update_form_boolean(socket, field, value)
       when field in ["conversation_enabled", "active"] do
    atom_field = String.to_existing_atom(field)
    changeset = Changeset.put_change(socket.assigns.changeset, atom_field, value)
    assign_changeset(socket, changeset)
  end

  defp normalize_filters(filters) do
    %{
      "name" => Map.get(filters, "name", ""),
      "model" => Map.get(filters, "model", ""),
      "conversation_enabled" => Map.get(filters, "conversation_enabled", "all"),
      "active" => Map.get(filters, "active", "all"),
      "sovereign" => Map.get(filters, "sovereign", "all")
    }
  end

  defp parse_form_attrs(attrs) do
    attrs =
      Map.put(
        attrs,
        "enabled_tool_keys",
        normalize_tool_keys(Map.get(attrs, "enabled_tool_keys", []))
      )

    case parse_advanced_options(Map.get(attrs, "advanced_options_json", "{}")) do
      {:ok, advanced_options} ->
        {:ok,
         attrs
         |> Map.put("advanced_options", advanced_options)
         |> Map.delete("advanced_options_json")}

      {:error, message} ->
        {:error, message, Map.delete(attrs, "advanced_options_json")}
    end
  end

  defp parse_advanced_options(json) when json in [nil, ""], do: {:ok, %{}}

  defp parse_advanced_options(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, "advanced options must be a JSON object"}
      {:error, _reason} -> {:error, "advanced options must be valid JSON"}
    end
  end

  defp parse_advanced_options(_), do: {:error, "advanced options must be valid JSON"}

  defp normalize_tool_keys(keys) when is_list(keys), do: Enum.reject(keys, &(&1 in [nil, ""]))
  defp normalize_tool_keys(key) when is_binary(key) and key != "", do: [key]
  defp normalize_tool_keys(_), do: []

  defp model_options_from_attrs(attrs, socket) do
    attrs
    |> Map.get("credential_id")
    |> model_options_for_credential(socket)
  end

  defp model_options_for_credential(nil, _socket), do: []
  defp model_options_for_credential("", _socket), do: []

  defp model_options_for_credential(credential_id, socket) when is_binary(credential_id) do
    case Integer.parse(credential_id) do
      {int_id, ""} -> model_options_for_credential(int_id, socket)
      _ -> []
    end
  end

  defp model_options_for_credential(credential_id, socket) when is_integer(credential_id) do
    case credential_for_id(socket.assigns.credentials_by_id, credential_id) do
      %{provider: provider} when is_binary(provider) ->
        provider
        |> models_for_provider()
        |> Enum.map(&{&1.id, &1.id})

      _ ->
        []
    end
  end

  defp models_for_provider(provider_id) when is_binary(provider_id) do
    provider_atom = String.to_existing_atom(provider_id)
    LLMDB.models(provider_atom)
  rescue
    ArgumentError -> []
  end

  defp pretty_json(map) when is_map(map) do
    case Jason.encode(map, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp pretty_json(_), do: "{}"

  defp selected_model_supports_tools(%Changeset{} = changeset, socket) do
    credential_id = Changeset.get_field(changeset, :credential_id)
    model_id = Changeset.get_field(changeset, :model)

    with true <- is_integer(credential_id),
         true <- is_binary(model_id),
         true <- model_id != "",
         %{provider: provider_id} when is_binary(provider_id) <-
           credential_for_id(socket.assigns.credentials_by_id, credential_id) do
      Registry.model_supports_tools?(provider_id, model_id)
    else
      _ -> nil
    end
  end

  defp credential_for_id(credentials_by_id, credential_id) when is_map(credentials_by_id) do
    Map.get(credentials_by_id, credential_id) || System.get_ai_provider_credential(credential_id)
  end

  defp show_field_errors?(%Changeset{action: action}) when action in [:insert, :update], do: true
  defp show_field_errors?(_), do: false

  defp error_messages(%Changeset{} = changeset, field) do
    if show_field_errors?(changeset), do: translate_errors(changeset.errors, field), else: []
  end

  attr :tools, :list, required: true
  attr :selected_keys, :list, required: true

  defp selected_tools_panel(assigns) do
    assigns =
      assign(
        assigns,
        :selected_tools,
        Enum.filter(assigns.tools, &(&1.key in assigns.selected_keys))
      )

    ~H"""
    <div class="rounded-lg border border-[#efece6]">
      <div :if={@selected_tools == []} class="px-3 py-2 font-mono text-[0.68rem] text-[#9a958c]">
        No tools selected.
      </div>
      <div :if={@selected_tools != []} class="max-h-44 overflow-y-auto divide-y divide-[#efece6]">
        <div
          :for={tool <- @selected_tools}
          data-selected-tool-key={tool.key}
          class="flex items-start justify-between gap-3 px-3 py-2 hover:bg-[#faf8f5]"
        >
          <div>
            <p class="font-mono text-[0.72rem] text-[#3e3b36]">{tool.label}</p>
            <p class="font-mono text-[0.64rem] text-[#8f8a82]">{tool.description}</p>
          </div>
          <button
            type="button"
            phx-click="remove_tool"
            phx-value-key={tool.key}
            class="w-6 h-6 rounded border border-black/15 text-black/35 hover:bg-black/5"
          >
            <svg
              class="w-3.5 h-3.5 mx-auto"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>
      </div>
    </div>
    """
  end
end
