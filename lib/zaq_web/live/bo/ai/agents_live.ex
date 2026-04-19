defmodule ZaqWeb.Live.BO.AI.AgentsLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Components.SearchableSelect

  alias Ecto.Changeset
  alias Zaq.Agent
  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Agent.ServerManager
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
    tools = Registry.tools()

    socket =
      socket
      |> assign(:current_path, "/bo/agents")
      |> assign(:filters, filters)
      |> assign(:credentials, credentials)
      |> assign(:tools, tools)
      |> assign(:page, 1)
      |> assign(:per_page, 20)
      |> assign(:mode, :idle)
      |> assign(:selected_agent_id, nil)
      |> assign(:model_options, [])
      |> assign(:selected_model_supports_tools, nil)
      |> assign(:advanced_options_json, "{}")
      |> assign(:advanced_options_error, nil)
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

  def handle_event("select_agent", %{"id" => id}, socket) do
    agent = Agent.get_agent!(id)

    {:noreply,
     socket
     |> assign(:mode, :edit)
     |> assign(:selected_agent_id, agent.id)
     |> assign(:model_options, model_options_for_credential(agent.credential_id))
     |> assign(:advanced_options_json, pretty_json(agent.advanced_options || %{}))
     |> assign(:advanced_options_error, nil)
     |> assign_changeset(Agent.change_agent(agent))}
  end

  def handle_event("validate", %{"configured_agent" => attrs}, socket) do
    base = current_form_agent(socket)

    case parse_form_attrs(attrs) do
      {:ok, parsed_attrs} ->
        changeset =
          base
          |> Agent.change_agent(parsed_attrs)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign_changeset(changeset)
         |> assign(:model_options, model_options_from_attrs(parsed_attrs))
         |> assign(:advanced_options_json, Map.get(attrs, "advanced_options_json", "{}"))
         |> assign(:advanced_options_error, nil)}

      {:error, message, parsed_attrs} ->
        changeset =
          base
          |> Agent.change_agent(parsed_attrs)
          |> Changeset.add_error(:advanced_options, message)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign_changeset(changeset)
         |> assign(:model_options, model_options_from_attrs(parsed_attrs))
         |> assign(:advanced_options_json, Map.get(attrs, "advanced_options_json", "{}"))
         |> assign(:advanced_options_error, message)}
    end
  end

  def handle_event("save", %{"configured_agent" => attrs}, socket) do
    case parse_form_attrs(attrs) do
      {:ok, parsed_attrs} ->
        save_agent(socket, parsed_attrs)

      {:error, message, parsed_attrs} ->
        base = current_form_agent(socket)

        changeset =
          base
          |> Agent.change_agent(parsed_attrs)
          |> Changeset.add_error(:advanced_options, message)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign_changeset(changeset)
         |> assign(:model_options, model_options_from_attrs(parsed_attrs))
         |> assign(:advanced_options_json, Map.get(attrs, "advanced_options_json", "{}"))
         |> assign(:advanced_options_error, message)}
    end
  end

  def handle_event("delete_agent", %{"id" => id}, socket) do
    agent = Agent.get_agent!(id)

    case Agent.delete_agent(agent) do
      {:ok, _deleted} ->
        _ = ServerManager.stop_server(id)

        socket =
          socket
          |> put_flash(:info, "Agent deleted")
          |> refresh_agents()

        {:noreply, reset_form_after_delete(socket, String.to_integer(id))}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete agent")}
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
             |> assign(:advanced_options_error, nil)
             |> assign(:advanced_options_json, pretty_json(agent.advanced_options || %{}))
             |> assign_changeset(Agent.change_agent(agent))
             |> assign(:model_options, model_options_for_credential(agent.credential_id))
             |> refresh_agents()}

          {:error, changeset} ->
            {:noreply, assign_changeset(socket, changeset)}
        end

      :edit ->
        agent = current_form_agent(socket)

        case Agent.update_agent(agent, attrs) do
          {:ok, updated} ->
            {:noreply,
             socket
             |> put_flash(:info, "Agent updated")
             |> assign(:advanced_options_error, nil)
             |> assign(:advanced_options_json, pretty_json(updated.advanced_options || %{}))
             |> assign_changeset(Agent.change_agent(updated))
             |> assign(:model_options, model_options_for_credential(updated.credential_id))
             |> refresh_agents()}

          {:error, changeset} ->
            {:noreply, assign_changeset(socket, changeset)}
        end
    end
  end

  defp current_form_agent(socket) do
    case socket.assigns do
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

    socket
    |> assign(:agents, agents)
    |> assign(:total_agents, total)
  end

  defp assign_new_changeset(socket) do
    assign_changeset(socket, Agent.change_agent(%ConfiguredAgent{}))
  end

  defp assign_changeset(socket, %Changeset{} = changeset) do
    socket
    |> assign(:changeset, changeset)
    |> assign(:selected_model_supports_tools, selected_model_supports_tools(changeset))
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
    |> assign(:model_options, [])
    |> assign(:advanced_options_json, "{}")
    |> assign(:advanced_options_error, nil)
    |> assign_new_changeset()
  end

  defp close_form(socket) do
    socket
    |> assign(:mode, :idle)
    |> assign(:selected_agent_id, nil)
    |> assign(:model_options, [])
    |> assign(:advanced_options_json, "{}")
    |> assign(:advanced_options_error, nil)
    |> assign_new_changeset()
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

  defp model_options_from_attrs(attrs) do
    attrs
    |> Map.get("credential_id")
    |> model_options_for_credential()
  end

  defp model_options_for_credential(nil), do: []
  defp model_options_for_credential(""), do: []

  defp model_options_for_credential(credential_id) when is_binary(credential_id) do
    case Integer.parse(credential_id) do
      {int_id, ""} -> model_options_for_credential(int_id)
      _ -> []
    end
  end

  defp model_options_for_credential(credential_id) when is_integer(credential_id) do
    case System.get_ai_provider_credential(credential_id) do
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

  defp selected_model_supports_tools(%Changeset{} = changeset) do
    credential_id = Changeset.get_field(changeset, :credential_id)
    model_id = Changeset.get_field(changeset, :model)

    with true <- is_integer(credential_id),
         true <- is_binary(model_id),
         true <- model_id != "",
         %{provider: provider_id} when is_binary(provider_id) <-
           System.get_ai_provider_credential(credential_id) do
      Registry.model_supports_tools?(provider_id, model_id)
    else
      _ -> nil
    end
  end
end
