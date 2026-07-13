defmodule ZaqWeb.Live.BO.AI.AgentsLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Components.AgentToolsPicker
  import ZaqWeb.Components.MarkdownEditor
  import ZaqWeb.Components.SearchableSelect
  import ZaqWeb.Live.BO.AI.AgentsTable, only: [agents_table: 1]

  alias Ecto.Changeset
  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.MCP
  alias Zaq.Agent.ProviderModels
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Event
  alias Zaq.NodeRouter
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
      |> assign(:job_preview, false)
      |> assign(:selected_agent_id, nil)
      |> assign(:selected_agent, nil)
      |> assign(:model_options, [])
      |> assign(:selected_model_supports_tools, nil)
      |> assign(:advanced_options_json, "{}")
      |> assign(:advanced_options_error, nil)
      |> assign(:form_notice, nil)
      |> assign(:tools_picker_open, false)
      |> assign(:tools_picker_value, "")
      |> assign(:mcp_picker_open, false)
      |> assign(:mcp_picker_value, "")
      |> assign(:mcp_notice, nil)
      |> assign(:mcp_endpoints, MCP.list_mcp_endpoints())
      |> assign(:skills_picker_open, false)
      |> assign(:skills_picker_value, "")
      |> assign(:skills_catalog, Skills.list_skills())
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

  def handle_event("toggle_job_preview", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :job_preview, mode == "preview")}
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

  def handle_event("open_skills_picker", _params, socket) do
    {:noreply, assign(socket, :skills_picker_open, true)}
  end

  def handle_event("close_skills_picker", _params, socket) do
    {:noreply, assign(socket, :skills_picker_open, false)}
  end

  def handle_event("add_skill_from_picker", %{"skill_id" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("add_skill_from_picker", %{"skill_id" => skill_id}, socket) do
    selected_ids = selected_skill_ids(socket)

    {:noreply,
     socket
     |> put_selected_skill_ids([skill_id | selected_ids])
     |> assign(:skills_picker_value, "")}
  end

  def handle_event("remove_skill", %{"id" => skill_id}, socket) do
    selected_ids = selected_skill_ids(socket)
    normalized_id = normalize_skill_id(skill_id)
    next_ids = Enum.reject(selected_ids, &(&1 == normalized_id))

    {:noreply, put_selected_skill_ids(socket, next_ids)}
  end

  def handle_event("open_mcp_picker", _params, socket) do
    enabled_unselected_mcp_options =
      socket.assigns.mcp_endpoints
      |> Enum.filter(&(&1.status == "enabled"))
      |> Enum.reject(&(&1.id in selected_mcp_endpoint_ids(socket)))

    cond do
      socket.assigns.selected_model_supports_tools == false ->
        {:noreply,
         socket
         |> assign(:mcp_picker_open, false)
         |> assign(
           :mcp_notice,
           "Selected model does not support tool calling. MCP endpoints and tools are unavailable for this model."
         )}

      enabled_unselected_mcp_options == [] ->
        {:noreply,
         socket
         |> assign(:mcp_picker_open, false)
         |> assign(
           :mcp_notice,
           "No active MCP endpoints found. Activate one in System Config."
         )}

      true ->
        {:noreply,
         socket
         |> assign(:mcp_notice, nil)
         |> assign(:mcp_picker_open, true)}
    end
  end

  def handle_event("close_mcp_picker", _params, socket) do
    {:noreply, assign(socket, :mcp_picker_open, false)}
  end

  def handle_event("add_mcp_from_picker", %{"endpoint_id" => ""}, socket) do
    {:noreply, socket}
  end

  def handle_event("add_mcp_from_picker", %{"endpoint_id" => endpoint_id}, socket) do
    selected_ids = selected_mcp_endpoint_ids(socket)

    {:noreply,
     socket
     |> put_selected_mcp_endpoint_ids([endpoint_id | selected_ids])
     |> assign(:mcp_picker_value, "")}
  end

  def handle_event("remove_mcp", %{"id" => endpoint_id}, socket) do
    selected_ids = selected_mcp_endpoint_ids(socket)
    normalized_id = normalize_mcp_endpoint_id(endpoint_id)
    next_ids = Enum.reject(selected_ids, &(&1 == normalized_id))

    {:noreply, put_selected_mcp_endpoint_ids(socket, next_ids)}
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
     |> assign(:job_preview, true)
     |> assign(:selected_agent_id, agent.id)
     |> assign(:selected_agent, agent)
     |> assign(:model_options, model_options_for_credential(agent.credential_id, socket))
     |> assign(:advanced_options_json, pretty_json(agent.advanced_options || %{}))
     |> assign(:advanced_options_error, nil)
     |> assign(:form_notice, nil)
     |> assign(:tools_picker_open, false)
     |> assign(:tools_picker_value, "")
     |> assign(:mcp_picker_open, false)
     |> assign(:mcp_picker_value, "")
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
        save_agent(socket |> assign(:form_notice, nil) |> clear_flash(:error), parsed_attrs)

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
    int_id = String.to_integer(id)

    event =
      Event.new(%{id: int_id}, :agent, opts: [action: :configured_agent_deleted])

    case NodeRouter.dispatch(event).response do
      {:ok, _payload} ->
        socket =
          socket
          |> put_flash(:info, "Agent deleted")
          |> refresh_agents()

        {:noreply, reset_form_after_delete(socket, int_id)}

      {:error, %Changeset{} = changeset} ->
        message =
          changeset
          |> Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Map.get(:base, [])
          |> List.first()
          |> Kernel.||("Failed to delete agent")

        {:noreply, put_flash(socket, :error, message)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete agent: #{inspect(reason)}")}

      other ->
        {:noreply, put_flash(socket, :error, "Failed to delete agent: #{inspect(other)}")}
    end
  end

  defp save_agent(socket, attrs) do
    case socket.assigns.mode do
      :new -> save_new_agent(socket, attrs)
      :edit -> save_existing_agent(socket, attrs)
    end
  end

  defp save_new_agent(socket, attrs) do
    event =
      Event.new(%{module: Agent, function: :create_agent, args: [attrs]}, :agent,
        opts: [action: :invoke]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, %ConfiguredAgent{} = agent} ->
        socket =
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
          |> assign(:mcp_endpoints, MCP.list_mcp_endpoints())
          |> refresh_agents()

        {:noreply, socket}

      {:ok, %{agent: agent} = payload} ->
        socket =
          socket
          |> put_flash(:info, "Agent created")
          |> maybe_put_runtime_warnings(payload)
          |> assign(:mode, :edit)
          |> assign(:selected_agent_id, agent.id)
          |> assign(:selected_agent, agent)
          |> assign(:advanced_options_error, nil)
          |> assign(:form_notice, nil)
          |> assign(:advanced_options_json, pretty_json(agent.advanced_options || %{}))
          |> assign_changeset(Agent.change_agent(agent))
          |> assign(:model_options, model_options_for_credential(agent.credential_id, socket))
          |> assign(:mcp_endpoints, MCP.list_mcp_endpoints())
          |> refresh_agents()

        {:noreply, socket}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_changeset(%{changeset | action: :insert})
         |> assign(:form_notice, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to create agent: #{inspect(reason)}")
         |> assign(:form_notice, nil)}
    end
  end

  defp save_existing_agent(socket, attrs) do
    agent = current_form_agent(socket)

    event =
      Event.new(%{id: agent.id, attrs: attrs}, :agent, opts: [action: :configured_agent_updated])

    case NodeRouter.dispatch(event).response do
      {:ok, %{agent: updated} = payload} ->
        socket =
          socket
          |> maybe_put_runtime_warnings(payload)
          |> assign(:selected_agent, updated)
          |> assign(:advanced_options_error, nil)
          |> assign(:form_notice, update_notice(payload))
          |> assign(:advanced_options_json, pretty_json(updated.advanced_options || %{}))
          |> assign_changeset(Agent.change_agent(updated))
          |> assign(:model_options, model_options_for_credential(updated.credential_id, socket))
          |> assign(:mcp_endpoints, MCP.list_mcp_endpoints())
          |> refresh_agents()

        {:noreply, socket}

      {:error, %Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign_changeset(%{changeset | action: :update})
         |> assign(:form_notice, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to update agent: #{inspect(reason)}")
         |> assign(:form_notice, nil)}
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
    |> assign(:mcp_notice, nil)
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
    |> reset_form_state(:new)
    |> assign_new_changeset()
  end

  defp close_form(socket) do
    socket
    |> reset_form_state(:idle)
    |> assign_new_changeset()
  end

  defp reset_form_state(socket, mode) when mode in [:new, :idle] do
    socket
    |> assign(:mode, mode)
    |> assign(:job_preview, false)
    |> assign(:selected_agent_id, nil)
    |> assign(:selected_agent, nil)
    |> assign(:model_options, [])
    |> assign(:advanced_options_json, "{}")
    |> assign(:advanced_options_error, nil)
    |> assign(:form_notice, nil)
    |> assign(:tools_picker_open, false)
    |> assign(:tools_picker_value, "")
    |> assign(:mcp_picker_open, false)
    |> assign(:mcp_picker_value, "")
    |> assign(:skills_picker_open, false)
    |> assign(:skills_picker_value, "")
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

  defp selected_mcp_endpoint_ids(socket) do
    socket.assigns.form[:enabled_mcp_endpoint_ids].value || []
  end

  defp put_selected_tools(socket, keys) do
    deduped_keys = keys |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
    changeset = Changeset.put_change(socket.assigns.changeset, :enabled_tool_keys, deduped_keys)

    assign_changeset(socket, changeset)
  end

  defp put_selected_mcp_endpoint_ids(socket, endpoint_ids) do
    normalized_ids = normalize_mcp_endpoint_ids(endpoint_ids)

    changeset =
      Changeset.put_change(socket.assigns.changeset, :enabled_mcp_endpoint_ids, normalized_ids)

    assign_changeset(socket, changeset)
  end

  defp selected_skill_ids(socket) do
    socket.assigns.form[:enabled_skill_ids].value || []
  end

  defp put_selected_skill_ids(socket, skill_ids) do
    normalized_ids = normalize_skill_ids(skill_ids)

    changeset =
      Changeset.put_change(socket.assigns.changeset, :enabled_skill_ids, normalized_ids)

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

    attrs =
      Map.put(
        attrs,
        "enabled_mcp_endpoint_ids",
        normalize_mcp_endpoint_ids(Map.get(attrs, "enabled_mcp_endpoint_ids", []))
      )

    attrs =
      Map.put(
        attrs,
        "enabled_skill_ids",
        normalize_skill_ids(Map.get(attrs, "enabled_skill_ids", []))
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

  defp normalize_mcp_endpoint_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&normalize_mcp_endpoint_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_mcp_endpoint_ids(id), do: normalize_mcp_endpoint_ids([id])

  defp normalize_mcp_endpoint_id(id) when is_integer(id) and id > 0, do: id

  defp normalize_mcp_endpoint_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 -> int_id
      _ -> nil
    end
  end

  defp normalize_mcp_endpoint_id(_), do: nil

  defp normalize_skill_ids(ids) when is_list(ids) do
    ids
    |> Enum.map(&normalize_skill_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp normalize_skill_ids(id), do: normalize_skill_ids([id])

  defp normalize_skill_id(id) when is_integer(id) and id > 0, do: id

  defp normalize_skill_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int_id, ""} when int_id > 0 -> int_id
      _ -> nil
    end
  end

  defp normalize_skill_id(_), do: nil

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
      credential ->
        credential
        |> ProviderModels.models_for_credential()
        |> Enum.sort_by(& &1.id)
        |> Enum.map(&{&1.id, &1.id})
    end
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

  attr :skills_catalog, :list, required: true
  attr :selected_skill_ids, :list, required: true

  defp selected_skills_panel(assigns) do
    skill_index = Map.new(assigns.skills_catalog, &{&1.id, &1})

    selected_skills =
      Enum.map(assigns.selected_skill_ids, fn skill_id ->
        case Map.get(skill_index, skill_id) do
          nil ->
            %{
              id: skill_id,
              name: "Unknown skill ##{skill_id}",
              description: "This skill has been removed.",
              active: false,
              ghost: true
            }

          skill ->
            skill
        end
      end)

    assigns = assign(assigns, :selected_skills, selected_skills)

    ~H"""
    <div class="rounded-lg border border-[#efece6]">
      <div :if={@selected_skills == []} class="px-3 py-2 font-mono text-[0.68rem] text-[#9a958c]">
        No skills attached.
      </div>
      <div :if={@selected_skills != []} class="max-h-44 overflow-y-auto divide-y divide-[#efece6]">
        <div
          :for={skill <- @selected_skills}
          data-selected-skill-id={skill.id}
          class={[
            "flex items-start justify-between gap-3 px-3 py-2",
            if(Map.get(skill, :ghost), do: "bg-red-50 hover:bg-red-100", else: "hover:bg-[#faf8f5]")
          ]}
        >
          <div>
            <p class={[
              "font-mono text-[0.72rem]",
              if(Map.get(skill, :ghost), do: "text-red-600", else: "text-[#3e3b36]")
            ]}>
              {skill.name}
              <span
                :if={Map.get(skill, :ghost)}
                class="ml-1.5 inline-block rounded bg-red-100 px-1 py-px font-mono text-[0.58rem] text-red-600"
              >
                Removed
              </span>
              <span
                :if={!Map.get(skill, :ghost) and !skill.active}
                class="ml-1.5 inline-block rounded bg-black/5 px-1 py-px font-mono text-[0.58rem] text-black/40"
              >
                Inactive
              </span>
            </p>
            <p class="font-mono text-[0.64rem] text-[#8f8a82]">{skill.description}</p>
          </div>
          <button
            type="button"
            phx-click="remove_skill"
            phx-value-id={skill.id}
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

  defp maybe_put_runtime_warnings(socket, payload) when is_map(payload) do
    warnings = runtime_warnings(payload)

    if warnings == [] do
      socket
    else
      put_flash(socket, :warning, "Agent saved with MCP warnings: #{inspect(warnings)}")
    end
  end

  defp maybe_put_runtime_warnings(socket, _), do: socket

  defp runtime_warnings(payload) when is_map(payload) do
    payload
    |> Map.get(:runtime, %{})
    |> map_get(:mcp_runtime, %{})
    |> map_get(:warnings, [])
  end

  defp update_notice(payload) when is_map(payload) do
    stopped = stopped_server_count(payload)

    case stopped do
      0 ->
        "Agent updated"

      1 ->
        "Agent updated. 1 runtime server stopped; it will restart on next message."

      n ->
        "Agent updated. #{n} runtime servers stopped; they will restart on next message."
    end
  end

  defp update_notice(_), do: "Agent updated"

  defp stopped_server_count(payload) when is_map(payload) do
    payload
    |> Map.get(:runtime, %{})
    |> map_get(:stopped_server_ids, [])
    |> case do
      ids when is_list(ids) -> length(ids)
      _ -> 0
    end
  end

  defp stopped_server_count(_), do: 0

  defp map_get(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp map_get(_map, _key, default), do: default
end
