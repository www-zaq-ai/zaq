defmodule ZaqWeb.Live.BO.AI.SkillsLive do
  @moduledoc """
  BO admin page for agent skills.

  Lists, searches (free text + tag), creates, edits, and deletes
  `Zaq.Agent.Skill` records. Reads go straight to `Zaq.Agent.Skills`; mutations
  that affect live agent runtimes (update, delete) are dispatched through
  `NodeRouter` with the `:agent_skill_updated` / `:agent_skill_deleted` actions
  so `Zaq.Agent.RuntimeSync` can fan out tool + MCP re-syncs.

  ## Skill resources

  Reference files are uploaded through the `"disk"` data-source bridge on the `:channels`
  role, which writes them under `.agents/skills/{slug}/references/` on an ingestion volume
  and registers a document row tagged `"public"`. The document id is recorded in
  `Skill.resources`, so listing and deleting resolve by id rather than by path.

  Uploads stage in the LiveView's buffer and are written by `save_skill/2`, whether the
  skill is being created or edited.
  """

  use ZaqWeb, :live_view

  import ZaqWeb.Components.AgentToolsPicker
  import ZaqWeb.Components.MarkdownEditor
  import ZaqWeb.Components.SearchableSelect

  alias Ecto.Changeset
  alias Zaq.Agent.MCP
  alias Zaq.Agent.Skill
  alias Zaq.Agent.Skill.Resources
  alias Zaq.Agent.Skills
  alias Zaq.Agent.Skills.Limits
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.ModalUpload
  alias ZaqWeb.Components.DesignSystem.Table, as: DSTable
  alias ZaqWeb.Components.Drawer
  alias ZaqWeb.Helpers.SizeFormat

  # Narrower than IngestionLive's list on purpose: skill resources are reference material
  # the agent reads, so only the formats that make sense in that role are accepted.
  @allowed_extensions ~w(.json .md .pdf .png)

  @provider "disk"

  # Public so an agent granted the skill can read the file back through `download_document`.
  @resource_tags ["public"]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:current_path, "/bo/skills")
      |> assign(:filters, %{"q" => "", "tag" => ""})
      |> assign(:tools, Registry.tools())
      |> assign(:mcp_endpoints, MCP.list_mcp_endpoints())
      |> assign(:mode, :idle)
      |> assign(:selected_skill, nil)
      |> assign(:form_tool_keys, [])
      |> assign(:form_mcp_endpoint_ids, [])
      |> assign(:tools_picker_open, false)
      |> assign(:tools_picker_value, "")
      |> assign(:mcp_picker_open, false)
      |> assign(:mcp_picker_value, "")
      |> assign(:body_preview, false)
      |> assign(:resource_modal, nil)
      |> assign(:upload_toast, nil)
      |> assign(:skill_resources, [])
      |> assign_volumes()
      # Size and count come from `Skills.Limits`, not from IngestionLive's rails: nothing
      # upstream caps a resource read (Jido's `load_resource/2` is an uncapped `File.read/1`),
      # so a 20 MB reference would be uploadable and then unusable.
      |> allow_upload(:skill_resources,
        accept: @allowed_extensions,
        max_entries: Limits.get(:resource_max_files),
        max_file_size: Limits.get(:resource_max_bytes)
      )
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
      # Staged entries belong to whichever skill the form was about. Starting over must
      # not carry the previous attempt's files into this one.
      |> drop_staged_resources()
      |> assign(:mode, :new)
      |> assign(:selected_skill, nil)
      |> assign(:form_tool_keys, [])
      |> assign(:form_mcp_endpoint_ids, [])
      |> assign(:tools_picker_open, false)
      |> assign(:tools_picker_value, "")
      |> assign(:mcp_picker_open, false)
      |> assign(:mcp_picker_value, "")
      |> assign(:body_preview, false)
      |> assign_changeset(Skills.change_skill(%Skill{}))

    {:noreply, socket}
  end

  def handle_event("toggle_body_preview", %{"mode" => mode}, socket) do
    {:noreply, assign(socket, :body_preview, mode == "preview")}
  end

  def handle_event("cancel_skill_form", _params, socket) do
    {:noreply, reset_form(socket)}
  end

  def handle_event("select_skill", %{"id" => id}, socket) do
    case Skills.get_skill(id) do
      %Skill{} = skill ->
        socket =
          socket
          # Switching skills abandons anything staged for the previous one. Without this,
          # the next upload here would consume those entries too and write another
          # skill's files into this one.
          |> drop_staged_resources()
          |> assign(:mode, :edit)
          |> assign(:selected_skill, skill)
          |> assign(:form_tool_keys, skill.tool_keys || [])
          |> assign(:form_mcp_endpoint_ids, skill.enabled_mcp_endpoint_ids || [])
          |> assign(:body_preview, true)
          |> assign_changeset(Skills.change_skill(skill))
          |> load_skill_resources()

        {:noreply, socket}

      nil ->
        {:noreply, put_flash(socket, :error, "Skill not found")}
    end
  end

  # Skill resources

  def handle_event("open_resource_upload", _params, socket) do
    if can_add_resources?(socket.assigns) do
      modal = if socket.assigns.volumes_connected?, do: :upload, else: :no_volume
      {:noreply, assign(socket, :resource_modal, modal)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_resource_modal", _params, socket) do
    {:noreply, assign(socket, :resource_modal, nil)}
  end

  def handle_event("dismiss_upload_toast", _params, socket) do
    {:noreply, assign(socket, :upload_toast, nil)}
  end

  def handle_event("select_resource_volume", %{"volume" => volume}, socket) do
    if volume in socket.assigns.volumes do
      {:noreply, assign(socket, :resource_volume, volume)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_skill_resource", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_skill_resource", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :skill_resources, ref)}
  end

  # Stages only — `save_skill/2` writes the entries.
  def handle_event("upload_skill_resource", _params, socket) do
    {:noreply, assign(socket, :resource_modal, nil)}
  end

  def handle_event("remove_skill_resource", %{"file_id" => file_id}, socket) do
    %Skill{} = skill = socket.assigns.selected_skill

    case delete_resource(skill, file_id) do
      :ok ->
        {:noreply, persist_resources(socket, skill, Resources.remove_reference(skill, file_id))}

      {:error, reason} ->
        {:noreply, put_toast(socket, :error, "Could not remove the file: #{inspect(reason)}")}
    end
  end

  def handle_event("open_tools_picker", _params, socket) do
    {:noreply, assign(socket, :tools_picker_open, true)}
  end

  def handle_event("close_tools_picker", _params, socket) do
    {:noreply, assign(socket, :tools_picker_open, false)}
  end

  def handle_event("add_tool_from_picker", %{"tool_key" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_tool_from_picker", %{"tool_key" => tool_key}, socket) do
    keys = Enum.uniq(socket.assigns.form_tool_keys ++ [tool_key])

    {:noreply,
     socket
     |> assign(:form_tool_keys, keys)
     |> assign(:tools_picker_value, "")}
  end

  def handle_event("remove_tool", %{"key" => tool_key}, socket) do
    keys = List.delete(socket.assigns.form_tool_keys, tool_key)
    {:noreply, assign(socket, :form_tool_keys, keys)}
  end

  def handle_event("open_mcp_picker", _params, socket) do
    {:noreply, assign(socket, :mcp_picker_open, true)}
  end

  def handle_event("close_mcp_picker", _params, socket) do
    {:noreply, assign(socket, :mcp_picker_open, false)}
  end

  def handle_event("add_mcp_from_picker", %{"endpoint_id" => ""}, socket), do: {:noreply, socket}

  def handle_event("add_mcp_from_picker", %{"endpoint_id" => endpoint_id}, socket) do
    ids =
      case normalize_endpoint_id(endpoint_id) do
        nil -> socket.assigns.form_mcp_endpoint_ids
        id -> Enum.uniq(socket.assigns.form_mcp_endpoint_ids ++ [id])
      end

    {:noreply,
     socket
     |> assign(:form_mcp_endpoint_ids, ids)
     |> assign(:mcp_picker_value, "")}
  end

  def handle_event("remove_mcp", %{"id" => endpoint_id}, socket) do
    ids = List.delete(socket.assigns.form_mcp_endpoint_ids, normalize_endpoint_id(endpoint_id))
    {:noreply, assign(socket, :form_mcp_endpoint_ids, ids)}
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
    skill_id = String.to_integer(id)
    # Read before deleting: the entries naming its documents are gone with the record.
    skill = Skills.get_skill(skill_id)
    event = Event.new(%{id: skill_id}, :agent, opts: [action: :agent_skill_deleted])

    case node_router().dispatch(event).response do
      {:ok, _payload} ->
        socket =
          socket
          |> put_delete_flash(delete_skill_resources(skill))
          |> reset_form()
          |> refresh_skills()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill: #{inspect(reason)}")}
    end
  end

  defp save_skill(%{assigns: %{mode: :new}} = socket, attrs) do
    event = Event.new(%{attrs: attrs}, :agent, opts: [action: :agent_skill_created])

    case node_router().dispatch(event).response do
      {:ok, %Skill{} = skill} ->
        # Only now does the destination exist. Anything staged while the form was open is
        # written here, against the name as *saved* — not the one typed at staging time.
        {uploaded, failed} = flush_staged_resources(socket, skill)

        socket =
          socket
          |> persist_resources(skill, Resources.add_references(skill, uploaded))
          |> put_create_flash(uploaded, failed)
          |> reset_form_state()
          |> refresh_skills()

        {:noreply, socket}

      {:error, %Changeset{} = changeset} ->
        {:noreply, assign_changeset(socket, Map.put(changeset, :action, :insert))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to create skill: #{inspect(reason)}")}
    end
  end

  defp save_skill(%{assigns: %{mode: :edit, selected_skill: %Skill{} = skill}} = socket, attrs) do
    {uploaded, failed} = flush_staged_resources(socket, skill)
    attrs = Map.put(attrs, "resources", Resources.add_references(skill, uploaded))
    event = Event.new(%{id: skill.id, attrs: attrs}, :agent, opts: [action: :agent_skill_updated])

    case node_router().dispatch(event).response do
      {:ok, %{skill: updated}} ->
        socket =
          socket
          |> put_save_flash(uploaded, failed)
          |> assign(:selected_skill, updated)
          |> assign(:form_tool_keys, updated.tool_keys || [])
          |> assign(:form_mcp_endpoint_ids, updated.enabled_mcp_endpoint_ids || [])
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
    |> Map.put("enabled_mcp_endpoint_ids", socket.assigns.form_mcp_endpoint_ids)
    |> Map.update("tags", [], &parse_tags/1)
    |> Map.update("allowed_tools", [], &parse_allowed_tools/1)
    |> Map.update("active", true, &(&1 in [true, "true", "on"]))
  end

  # `allowed_tools` is the OAS field — a space- (or comma-) separated list of tool NAMES.
  # The changeset normalizes further (trims, dedupes); this just turns the form string
  # into the list it expects.
  defp parse_allowed_tools(value) when is_binary(value) do
    value
    |> String.split(~r/[\s,]+/, trim: true)
  end

  defp parse_allowed_tools(value) when is_list(value), do: value
  defp parse_allowed_tools(_), do: []

  defp normalize_endpoint_id(id) when is_integer(id), do: id

  defp normalize_endpoint_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_endpoint_id(_), do: nil

  defp parse_tags(tags) when is_binary(tags) do
    tags
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_tags(tags) when is_list(tags), do: tags
  defp parse_tags(_), do: []

  # ── Skill resources ─────────────────────────────────────────────

  defp assign_volumes(socket) do
    stats = channel_stats()
    volumes = Map.get(stats, :root_folders, [])

    socket
    |> assign(:volumes, volumes)
    |> assign(:volumes_connected?, Map.get(stats, :volumes_configured?, false) == true)
    |> assign(:resource_volume, List.first(volumes))
  end

  # A degraded ingestion role yields no volumes, which the modal renders as "connect a volume".
  defp channel_stats do
    case data_source_dispatch(:data_source_channel_stats, %{}) do
      {:ok, stats} when is_map(stats) -> stats
      _ -> %{}
    end
  end

  # Resources need a destination, and the destination needs a name. A saved skill always
  # has one; an unsaved one has whatever is currently typed into the form.
  defp can_add_resources?(%{mode: :edit, selected_skill: %Skill{}}), do: true
  defp can_add_resources?(%{mode: :new, form: form}), do: present?(form[:name].value)
  defp can_add_resources?(_assigns), do: false

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # The skill a destination path is derived from: the saved record when editing, or a
  # stand-in carrying the typed name when creating. Nothing is written from the stand-in —
  # it only renders the path preview in the modal.
  defp resource_target(%{mode: :edit, selected_skill: %Skill{} = skill}), do: skill
  defp resource_target(%{form: form}), do: %Skill{name: form[:name].value}

  # Writes the staged entries against the skill as saved. Returns `{uploaded, failed}` —
  # `uploaded` are resource entries ready to append to the skill's references bucket.
  defp flush_staged_resources(socket, %Skill{} = skill) do
    volume = socket.assigns.resource_volume
    entries = socket.assigns.uploads.skill_resources.entries

    if is_binary(volume) and entries != [] and Enum.all?(entries, &(&1.progress == 100)) do
      socket
      |> consume_uploaded_entries(:skill_resources, fn %{path: tmp_path}, entry ->
        {:ok, upload_resource(skill, volume, tmp_path, entry)}
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))
      |> then(fn {uploaded, failed} -> {Enum.map(uploaded, &elem(&1, 1)), failed} end)
    else
      {[], []}
    end
  end

  # Uploads one file and returns the entry naming the document it created.
  defp upload_resource(%Skill{} = skill, volume, tmp_path, entry) do
    with {:ok, binary} <- File.read(tmp_path),
         {:ok, %{record: record}} <- create_file(skill, volume, binary, entry.client_name) do
      {:ok, Resources.entry(record.id, record.name, @provider)}
    end
  end

  defp create_file(%Skill{} = skill, volume, binary, filename) do
    params = %{
      "path" => Path.join(volume, Resources.references_dir(skill)),
      "name" => Path.basename(Resources.destination(skill, filename)),
      "content" => Base.encode64(binary),
      "encoding" => "base64",
      "tags" => @resource_tags
    }

    data_source_dispatch(:data_source_create_file, params)
  end

  defp delete_resource(%Skill{} = skill, file_id) do
    case Enum.find(Resources.references(skill), &(&1["file_id"] == file_id)) do
      nil -> {:error, :not_found}
      entry -> file_id |> delete_file(entry["provider"]) |> normalize_delete()
    end
  end

  defp delete_file(file_id, provider) do
    data_source_dispatch(:data_source_delete_file, %{"file_id" => file_id}, provider)
  end

  defp normalize_delete({:ok, _payload}), do: :ok
  defp normalize_delete(other), do: other

  # Removes every document the skill recorded. Runs after the record is deleted.
  defp delete_skill_resources(nil), do: []

  defp delete_skill_resources(%Skill{} = skill) do
    skill
    |> Resources.references()
    |> Enum.map(&(&1["file_id"] |> delete_file(&1["provider"]) |> normalize_delete()))
    |> Enum.reject(&(&1 == :ok))
  end

  # Writes the resources map back onto the skill and refreshes what the drawer renders from.
  defp persist_resources(socket, %Skill{} = skill, resources) do
    event =
      Event.new(%{id: skill.id, attrs: %{"resources" => resources}}, :agent,
        opts: [action: :agent_skill_updated]
      )

    case node_router().dispatch(event).response do
      {:ok, %{skill: updated}} ->
        socket
        |> assign(:selected_skill, updated)
        |> assign(:skill_resources, Resources.references(updated))
        |> refresh_skills()

      _ ->
        socket
    end
  end

  defp load_skill_resources(%{assigns: %{selected_skill: %Skill{} = skill}} = socket) do
    assign(socket, :skill_resources, Resources.references(skill))
  end

  defp load_skill_resources(socket), do: assign(socket, :skill_resources, [])

  defp references_dir(%Skill{} = skill), do: Resources.references_dir(skill)

  # Shown in the upload modal so the operator can see where the file will land in the
  # ingestion browser before committing to it. Template-facing.
  defp resource_destination(assigns), do: references_dir(resource_target(assigns))

  # Template-facing wrapper — the button's visibility gate.
  defp resources_addable?(assigns), do: can_add_resources?(assigns)

  # Built from the same two values `allow_upload/3` is configured with, so the dropzone
  # cannot advertise a cap the server does not enforce.
  defp resource_upload_hint do
    extensions = Enum.join(@allowed_extensions, " ")
    max = SizeFormat.format_size(Limits.get(:resource_max_bytes))

    "#{extensions} — max #{max}"
  end

  defp put_create_flash(socket, [], []), do: put_flash(socket, :info, "Skill created")

  defp put_create_flash(socket, uploaded, []) do
    put_flash(socket, :info, "Skill created with #{length(uploaded)} resource(s).")
  end

  defp put_create_flash(socket, uploaded, failed) do
    put_flash(
      socket,
      :error,
      "Skill created with #{length(uploaded)} resource(s). " <>
        "#{length(failed)} could not be uploaded."
    )
  end

  # An overlay toast, not a BOLayout flash — the drawer stays open on save.
  defp put_save_flash(socket, [], []), do: put_toast(socket, :info, "Skill saved")

  defp put_save_flash(socket, uploaded, []) do
    put_toast(socket, :info, "Skill saved with #{length(uploaded)} resource(s) added.")
  end

  defp put_save_flash(socket, uploaded, failed) do
    put_toast(
      socket,
      :error,
      "Skill saved with #{length(uploaded)} resource(s) added. " <>
        "#{length(failed)} could not be uploaded."
    )
  end

  defp put_delete_flash(socket, []), do: put_flash(socket, :info, "Skill deleted")

  defp put_delete_flash(socket, errors) do
    put_flash(
      socket,
      :error,
      "Skill deleted, but its resources could not be removed: #{inspect(errors)}"
    )
  end

  defp put_toast(socket, kind, message) do
    assign(socket, :upload_toast, %{kind: kind, message: message})
  end

  # Every filesystem hop goes through the disk bridge on the channels node.
  defp data_source_dispatch(action, params, provider \\ @provider) do
    %{provider: provider, params: params}
    |> Event.new(:channels, opts: [action: action])
    |> node_router().dispatch()
    |> Map.fetch!(:response)
  end

  defp form_base_skill(%{assigns: %{mode: :edit, selected_skill: %Skill{} = skill}}), do: skill
  defp form_base_skill(_socket), do: %Skill{}

  defp reset_form(socket) do
    socket
    |> drop_staged_resources()
    |> reset_form_state()
  end

  # Used after a create has already consumed the staged entries: cancelling them again
  # would call into upload processes that no longer exist.
  defp reset_form_state(socket) do
    socket
    |> assign(:mode, :idle)
    |> assign(:selected_skill, nil)
    |> assign(:form_tool_keys, [])
    |> assign(:form_mcp_endpoint_ids, [])
    |> assign(:tools_picker_open, false)
    |> assign(:tools_picker_value, "")
    |> assign(:mcp_picker_open, false)
    |> assign(:mcp_picker_value, "")
    |> assign(:body_preview, false)
    |> assign(:resource_modal, nil)
    |> assign(:skill_resources, [])
    |> assign_changeset(Skills.change_skill(%Skill{}))
  end

  # Abandoning the form must not leave staged entries to be flushed into whatever skill is
  # created or selected next.
  defp drop_staged_resources(socket) do
    Enum.reduce(socket.assigns.uploads.skill_resources.entries, socket, fn entry, acc ->
      cancel_upload(acc, :skill_resources, entry.ref)
    end)
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

  defp node_router, do: Application.get_env(:zaq, :skills_live_node_router_module, NodeRouter)

  defp tags_to_string(tags) when is_list(tags), do: Enum.join(tags, ", ")
  defp tags_to_string(tags) when is_binary(tags), do: tags
  defp tags_to_string(_), do: ""

  # OAS `allowed-tools` renders back as its space-separated form (matching how the spec
  # encodes it in SKILL.md).
  defp allowed_tools_to_string(tools) when is_list(tools), do: Enum.join(tools, " ")
  defp allowed_tools_to_string(tools) when is_binary(tools), do: tools
  defp allowed_tools_to_string(_), do: ""

  defp field_errors(%Phoenix.HTML.FormField{errors: errors}) do
    Enum.map(errors, &ZaqWeb.CoreComponents.translate_error/1)
  end
end
