defmodule ZaqWeb.Live.BO.AI.SkillsLive do
  @moduledoc """
  BO admin page for agent skills.

  Lists, searches (free text + tag), creates, edits, and deletes
  `Zaq.Agent.Skill` records. Reads go straight to `Zaq.Agent.Skills`; mutations
  that affect live agent runtimes (update, delete) are dispatched through
  `NodeRouter` with the `:agent_skill_updated` / `:agent_skill_deleted` actions
  so `Zaq.Agent.RuntimeSync` can fan out tool re-syncs.
  """

  use ZaqWeb, :live_view

  alias Ecto.Changeset
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Event
  alias Zaq.NodeRouter

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, "/bo/skills")
      |> assign(:filters, %{"q" => "", "tag" => ""})
      |> assign(:tools, Registry.tools())
      |> assign(:mode, :idle)
      |> assign(:selected_skill, nil)
      |> assign(:form_tool_keys, [])
      |> refresh_skills()

    {:ok, assign_changeset(socket, Skills.change_skill(%Skill{}))}
  end

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    socket =
      socket
      |> assign(:filters, Map.merge(socket.assigns.filters, filters))
      |> refresh_skills()

    {:noreply, socket}
  end

  def handle_event("new_skill", _params, socket) do
    socket =
      socket
      |> assign(:mode, :new)
      |> assign(:selected_skill, nil)
      |> assign(:form_tool_keys, [])
      |> assign_changeset(Skills.change_skill(%Skill{}))

    {:noreply, socket}
  end

  def handle_event("cancel_form", _params, socket) do
    {:noreply, reset_form(socket)}
  end

  def handle_event("select_skill", %{"id" => id}, socket) do
    case Skills.get_skill(id) do
      %Skill{} = skill ->
        socket =
          socket
          |> assign(:mode, :edit)
          |> assign(:selected_skill, skill)
          |> assign(:form_tool_keys, skill.tool_keys || [])
          |> assign_changeset(Skills.change_skill(skill))

        {:noreply, socket}

      nil ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  def handle_event("add_tool", %{"tool_key" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_tool", %{"tool_key" => tool_key}, socket) do
    keys = Enum.uniq(socket.assigns.form_tool_keys ++ [tool_key])
    {:noreply, assign(socket, :form_tool_keys, keys)}
  end

  def handle_event("remove_tool", %{"key" => tool_key}, socket) do
    keys = List.delete(socket.assigns.form_tool_keys, tool_key)
    {:noreply, assign(socket, :form_tool_keys, keys)}
  end

  def handle_event("validate", %{"skill" => attrs}, socket) do
    changeset =
      socket
      |> form_base_skill()
      |> Skills.change_skill(form_attrs(attrs, socket))
      |> Map.put(:action, :validate)

    {:noreply, assign_changeset(socket, changeset)}
  end

  def handle_event("save", %{"skill" => attrs}, socket) do
    save_skill(socket, form_attrs(attrs, socket))
  end

  def handle_event("delete_skill", %{"id" => id}, socket) do
    event =
      Event.new(%{id: String.to_integer(id)}, :agent, opts: [action: :agent_skill_deleted])

    case NodeRouter.dispatch(event).response do
      {:ok, _payload} ->
        socket =
          socket
          |> put_flash(:info, "Skill deleted")
          |> reset_form()
          |> refresh_skills()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill: #{inspect(reason)}")}
    end
  end

  defp save_skill(%{assigns: %{mode: :new}} = socket, attrs) do
    event =
      Event.new(%{module: Skills, function: :create_skill, args: [attrs]}, :agent,
        opts: [action: :invoke]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, %Skill{} = skill} ->
        socket =
          socket
          |> put_flash(:info, "Skill created")
          |> assign(:mode, :edit)
          |> assign(:selected_skill, skill)
          |> assign(:form_tool_keys, skill.tool_keys || [])
          |> assign_changeset(Skills.change_skill(skill))
          |> refresh_skills()

        {:noreply, socket}

      {:error, %Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, Map.put(changeset, :action, :insert))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create skill: #{inspect(reason)}")}
    end
  end

  defp save_skill(%{assigns: %{mode: :edit, selected_skill: %Skill{} = skill}} = socket, attrs) do
    event =
      Event.new(%{id: skill.id, attrs: attrs}, :agent, opts: [action: :agent_skill_updated])

    case NodeRouter.dispatch(event).response do
      {:ok, %{skill: updated}} ->
        socket =
          socket
          |> put_flash(:info, "Skill saved")
          |> assign(:selected_skill, updated)
          |> assign(:form_tool_keys, updated.tool_keys || [])
          |> assign_changeset(Skills.change_skill(updated))
          |> refresh_skills()

        {:noreply, socket}

      {:error, %Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, Map.put(changeset, :action, :update))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to save skill: #{inspect(reason)}")}
    end
  end

  defp form_attrs(attrs, socket) do
    attrs
    |> Map.put("tool_keys", socket.assigns.form_tool_keys)
    |> Map.update("tags", [], &parse_tags/1)
    |> Map.update("active", true, &(&1 in [true, "true", "on"]))
  end

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(tags) when is_list(tags), do: tags
  defp parse_tags(_), do: []

  defp form_base_skill(%{assigns: %{mode: :edit, selected_skill: %Skill{} = skill}}), do: skill
  defp form_base_skill(_socket), do: %Skill{}

  defp reset_form(socket) do
    socket
    |> assign(:mode, :idle)
    |> assign(:selected_skill, nil)
    |> assign(:form_tool_keys, [])
    |> assign_changeset(Skills.change_skill(%Skill{}))
  end

  defp refresh_skills(socket) do
    filters = socket.assigns.filters

    search = %{
      q: filters["q"] || "",
      tags: parse_tags(filters["tag"] || "")
    }

    assign(socket, :skills, Skills.search_skills(search))
  end

  defp assign_changeset(socket, changeset) do
    assign(socket, :form, to_form(changeset, as: :skill))
  end

  defp tool_label(tools, tool_key) do
    case Enum.find(tools, &(&1.key == tool_key)) do
      %{label: label} -> label
      _ -> tool_key
    end
  end

  defp tags_to_string(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp tags_to_string(tags) when is_binary(tags), do: tags
  defp tags_to_string(_), do: ""

  defp field_errors(%Phoenix.HTML.FormField{errors: errors}) do
    Enum.map(errors, &ZaqWeb.CoreComponents.translate_error/1)
  end
end
