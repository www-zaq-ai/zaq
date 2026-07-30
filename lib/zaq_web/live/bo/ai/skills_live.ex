defmodule ZaqWeb.Live.BO.AI.SkillsLive do
  @moduledoc """
  BO admin page for agent skills.

  Lists, searches (free text + tag), creates, edits, and deletes
  `Zaq.Agent.Skill` records. Reads go straight to `Zaq.Agent.Skills`; mutations
  that affect live agent runtimes (update, delete) are dispatched through
  `NodeRouter` with the `:agent_skill_updated` / `:agent_skill_deleted` actions
  so `Zaq.Agent.RuntimeSync` can fan out tool + MCP re-syncs.

  ## Skill resources

  A skill's reference files are uploaded here but stored by **ingestion**, under
  `.agents/skills/{slug}/references/` on a volume — so they appear in the ingestion
  browser like any other file and need no separate storage. Every filesystem hop goes
  through `NodeRouter` to the `:ingestion` role: the BO node is not guaranteed to have
  the volume mounted. Path derivation is `Zaq.Agent.Skill.Resources`' job, not this
  module's.

  Uploading requires an explicitly configured volume (`Ingestion.volumes_configured?/0`),
  not merely a non-empty `list_volumes/0` — that call synthesizes a `"default"` entry and
  can never be empty.
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
  alias Zaq.Agent.Tools.Registry
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.Table, as: DSTable
  alias ZaqWeb.Components.Drawer
  alias ZaqWeb.Helpers.UploadFlash

  # Mirrors IngestionLive's upload rails so a file accepted here is a file ingestion
  # would have accepted anyway.
  @allowed_extensions ~w(.md .txt .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg)
  @max_entries 10
  @max_file_size 20_000_000

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
      |> assign(:skill_resources, [])
      |> assign_volumes()
      |> allow_upload(:skill_resources,
        accept: @allowed_extensions,
        max_entries: @max_entries,
        max_file_size: @max_file_size
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

  def handle_event("select_resource_volume", %{"volume" => volume}, socket) do
    if Map.has_key?(socket.assigns.volumes, volume) do
      {:noreply, socket |> assign(:resource_volume, volume) |> load_skill_resources()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_skill_resource", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_skill_resource", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :skill_resources, ref)}
  end

  # On a skill that does not exist yet there is nowhere to write: leave the entries in the
  # LiveView's upload buffer and close the modal. They are written by `save_skill/2` once
  # the record — and therefore the destination path — exists. Phoenix garbage-collects
  # unconsumed entries if this LiveView dies, so abandoning the form leaves nothing behind.
  def handle_event("upload_skill_resource", _params, %{assigns: %{mode: :new}} = socket) do
    {:noreply, assign(socket, :resource_modal, nil)}
  end

  def handle_event(
        "upload_skill_resource",
        _params,
        %{assigns: %{mode: :edit, selected_skill: %Skill{} = skill}} = socket
      ) do
    if Enum.all?(socket.assigns.uploads.skill_resources.entries, &(&1.progress == 100)) do
      volume = socket.assigns.resource_volume

      results =
        consume_uploaded_entries(socket, :skill_resources, fn %{path: tmp_path}, entry ->
          {:ok, upload_resource(skill, volume, tmp_path, entry)}
        end)

      {uploaded, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

      socket =
        socket
        |> maybe_persist_resource_root(skill, uploaded)
        |> load_skill_resources()
        |> put_resource_upload_flash(uploaded, failed)
        |> maybe_close_resource_modal(uploaded, failed)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("upload_skill_resource", _params, socket), do: {:noreply, socket}

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
    # Read the skill before deleting it: its resource root is derived from fields that are
    # gone once the record is.
    skill = Skills.get_skill(skill_id)

    event = Event.new(%{id: skill_id}, :agent, opts: [action: :agent_skill_deleted])

    case node_router().dispatch(event).response do
      {:ok, _payload} ->
        socket =
          socket
          |> put_delete_flash(delete_skill_resources(socket, skill))
          |> reset_form()
          |> refresh_skills()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete skill: #{inspect(reason)}")}
    end
  end

  defp save_skill(%{assigns: %{mode: :new}} = socket, attrs) do
    # Creation dispatches straight to `Skills.create_skill/1` via `:invoke` rather
    # than through `RuntimeSync` (as update/delete do): a brand-new skill has no
    # agent references yet, so there is nothing to fan out to live agent servers.
    # Runtime propagation only becomes relevant once the skill is attached to an
    # agent, which happens through the agent form's own sync path.
    event =
      Event.new(%{module: Skills, function: :create_skill, args: [attrs]}, :agent,
        opts: [action: :invoke]
      )

    case node_router().dispatch(event).response do
      {:ok, %Skill{} = skill} ->
        # Only now does the destination exist. Anything staged while the form was open is
        # written here, against the name as *saved* — not the one typed at staging time.
        {uploaded, failed} = flush_staged_resources(socket, skill)

        # The drawer closes on create, so the flash — not the resources table — is what
        # reports whether the staged files made it to the volume.
        socket =
          socket
          |> maybe_persist_resource_root(skill, uploaded)
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
    event =
      Event.new(%{id: skill.id, attrs: attrs}, :agent, opts: [action: :agent_skill_updated])

    case node_router().dispatch(event).response do
      {:ok, %{skill: updated}} ->
        socket =
          socket
          |> put_flash(:info, "Skill saved")
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
    volumes =
      case ingestion_invoke(:list_volumes, []) do
        volumes when is_map(volumes) -> volumes
        _ -> %{}
      end

    socket
    |> assign(:volumes, volumes)
    |> assign(:volumes_connected?, ingestion_invoke(:volumes_configured?, []) == true)
    |> assign(:resource_volume, default_volume(volumes))
  end

  # `Map.keys/1` ordering is not guaranteed, so sort rather than take whichever key the
  # map happens to yield first — otherwise the preselected volume could differ per node.
  defp default_volume(volumes) do
    volumes |> Map.keys() |> Enum.sort() |> List.first()
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

  # Writes entries staged while the skill did not exist. Returns the `{uploaded, failed}`
  # split so the caller can both flash and decide whether to persist `resource_root`.
  defp flush_staged_resources(socket, %Skill{} = skill) do
    volume = socket.assigns.resource_volume
    entries = socket.assigns.uploads.skill_resources.entries

    if is_binary(volume) and entries != [] and Enum.all?(entries, &(&1.progress == 100)) do
      socket
      |> consume_uploaded_entries(:skill_resources, fn %{path: tmp_path}, entry ->
        {:ok, upload_resource(skill, volume, tmp_path, entry)}
      end)
      |> Enum.split_with(&match?({:ok, _}, &1))
    else
      {[], []}
    end
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

  defp upload_resource(skill, volume, tmp_path, entry) do
    destination = Resources.destination(skill, entry.client_name)

    # Both failure shapes are already `{:error, reason}`, so they fall through as-is.
    with {:ok, binary} <- File.read(tmp_path),
         {:ok, written} <- ingestion_invoke(:upload_file, [volume, destination, binary]) do
      # Same as IngestionLive: track immediately so the file browser sees the file
      # without waiting for a filesystem watcher.
      ingestion_invoke(:track_upload, [volume, written])
      {:ok, written}
    end
  end

  # Written once, on the first successful upload, and never recomputed — a later rename
  # must not strand files already sitting under the original root.
  defp maybe_persist_resource_root(socket, %Skill{resource_root: nil} = skill, [_ | _]) do
    attrs = %{"resource_root" => Resources.default_root(skill)}
    event = Event.new(%{id: skill.id, attrs: attrs}, :agent, opts: [action: :agent_skill_updated])

    case node_router().dispatch(event).response do
      {:ok, %{skill: updated}} ->
        socket
        |> assign(:selected_skill, updated)
        |> assign_changeset(Skills.change_skill(updated))
        |> refresh_skills()

      _ ->
        socket
    end
  end

  defp maybe_persist_resource_root(socket, _skill, _uploaded), do: socket

  defp load_skill_resources(
         %{assigns: %{selected_skill: %Skill{} = skill, resource_volume: volume}} = socket
       )
       when is_binary(volume) do
    entries =
      case ingestion_invoke(:list_entries, [volume, references_dir(skill)]) do
        {:ok, entries} when is_list(entries) -> Enum.filter(entries, &(&1.type == :file))
        # A skill with no uploads yet has no directory — that is the empty state, not an error.
        _ -> []
      end

    assign(socket, :skill_resources, entries)
  end

  # No skill selected, or no volume to read from (nothing configured, or the ingestion node
  # did not answer). `FileExplorer.list/2` requires a binary volume, so guard rather than
  # let a degraded ingestion role crash the page.
  defp load_skill_resources(socket), do: assign(socket, :skill_resources, [])

  defp references_dir(%Skill{} = skill), do: Resources.references_dir(skill)

  # Shown in the upload modal so the operator can see where the file will land in the
  # ingestion browser before committing to it. Template-facing.
  defp resource_destination(assigns), do: references_dir(resource_target(assigns))

  # Template-facing wrapper — the button's visibility gate.
  defp resources_addable?(assigns), do: can_add_resources?(assigns)

  # Removes a deleted skill's whole resource directory — `.agents/skills/{slug}`, not just
  # its `references/` child.
  #
  # The volume is swept rather than looked up: the upload modal lets the operator choose a
  # volume, but only the volume-relative `resource_root` is persisted, so which volume
  # holds the files is not recoverable from the skill. Sweeping is safe because the root is
  # namespaced per skill, and volumes without the directory are skipped.
  #
  # Runs *after* the record is deleted. If it fails, the skill is still gone and the files
  # remain visible in the ingestion browser — recoverable. The reverse order could strip a
  # live skill's resources when the record deletion then failed.
  defp delete_skill_resources(_socket, nil), do: []

  defp delete_skill_resources(socket, %Skill{} = skill) do
    root = Resources.root(skill)

    socket.assigns.volumes
    |> Map.keys()
    |> Enum.map(&delete_resource_dir(&1, root))
    |> Enum.reject(&(&1 == :absent))
  end

  # A skill that never had a resource uploaded has no directory. `delete_path/3` surfaces
  # `{:error, :not_a_directory}` for a missing path, so check before asking.
  defp delete_resource_dir(volume, root) do
    case ingestion_invoke(:file_info, [volume, root]) do
      {:ok, %{type: :directory}} ->
        # `delete_path/4` also clears the tracked `Document` rows under the folder, which
        # `track_upload/2` created at upload time.
        ingestion_invoke(:delete_path, [volume, root, "directory"])

      _ ->
        :absent
    end
  end

  defp put_delete_flash(socket, results) do
    case Enum.reject(results, &(&1 == :ok)) do
      [] ->
        put_flash(socket, :info, "Skill deleted")

      errors ->
        put_flash(
          socket,
          :error,
          "Skill deleted, but its resources could not be removed: #{inspect(errors)}"
        )
    end
  end

  defp put_resource_upload_flash(socket, uploaded, failed) do
    UploadFlash.put_result(socket, uploaded, failed, noun: "resource", past_tense: "added")
  end

  defp maybe_close_resource_modal(socket, uploaded, failed) do
    if uploaded != [] and failed == [] do
      assign(socket, :resource_modal, nil)
    else
      socket
    end
  end

  defp ingestion_invoke(fun, args) do
    event =
      Event.new(%{module: Ingestion, function: fun, args: args}, :ingestion,
        opts: [action: :invoke]
      )

    node_router().dispatch(event).response
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
