defmodule ZaqWeb.Live.BO.AI.SkillsLive do
  @moduledoc """
  BO admin page for agent skills.

  Lists, searches (free text + tag), creates, edits, and deletes
  `Zaq.Agent.Skill` records. Reads go straight to `Zaq.Agent.Skills`; mutations
  that affect live agent runtimes (update, delete) are dispatched through
  `NodeRouter` with the `:agent_skill_updated` / `:agent_skill_deleted` actions
  so `Zaq.Agent.RuntimeSync` can fan out tool + MCP re-syncs.

  ## Skill resources

  Reference files are uploaded here but stored by ingestion, under
  `.agents/skills/{slug}/references/` on a volume, where they appear in the ingestion
  browser like any other file. `Zaq.Agent.Skill.Resources` derives the path.

  Uploads go through the `disk` datasource provider (`Zaq.Channels.DiskBridge`) rather than
  calling `Zaq.Ingestion` directly, so a single dispatch writes the file, registers its
  document row and applies its tags — two separate calls could leave a file on disk with no
  row pointing at it. The skill row stores only the returned document id.

  Files are tagged `"public"` at write time. `Zaq.Ingestion.RecordMaterializer`
  permission-checks every read with no bypass, so that tag is what makes a reference
  readable by an agent acting without a person. It also makes the file visible in ingestion
  browse and ordinary retrieval, not only through `load_skill`.

  Uploading requires an explicitly configured volume (`Ingestion.volumes_configured?/0`)
  rather than a non-empty `list_volumes/0`, which synthesizes a `"default"` entry and can
  never be empty.
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
  alias Zaq.Contracts.RecordPage
  alias Zaq.Event
  alias Zaq.Ingestion
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.ModalUpload
  alias ZaqWeb.Components.DesignSystem.Table, as: DSTable
  alias ZaqWeb.Components.Drawer
  alias ZaqWeb.Helpers.SizeFormat

  # Narrower than IngestionLive's list on purpose: skill resources are reference material
  # the agent reads, so only the formats that make sense in that role are accepted.
  @allowed_extensions ~w(.json .md .pdf .png)

  # Skill files live on an ingestion volume, reached as a datasource.
  @resource_provider "disk"

  # Applied by ingestion at write time. An agent loading a skill has no person to check
  # against, and `RecordMaterializer` grants nothing implicitly, so without this tag every
  # reference would be unreadable. Marking the *folder* public instead would not work:
  # folder settings are not applied to documents created later.
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
        |> persist_references(skill, uploaded)
        |> load_skill_resources()
        |> put_resource_upload_toast(uploaded, failed)
        |> maybe_close_resource_modal(uploaded, failed)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_event("upload_skill_resource", _params, socket), do: {:noreply, socket}

  # Deletes the document, then drops the reference. That order leaves a recoverable state if
  # the second step fails — a reference to a file that is gone renders as a missing entry —
  # whereas the reverse would orphan a file nothing points at.
  def handle_event(
        "remove_skill_resource",
        %{"file_id" => file_id},
        %{assigns: %{selected_skill: %Skill{} = skill}} = socket
      ) do
    reference = Enum.find(Resources.references(skill), &(Map.get(&1, "file_id") == file_id))

    case reference && delete_reference_file(reference) do
      nil ->
        {:noreply, socket}

      :ok ->
        {:noreply, drop_reference(socket, skill, file_id)}

      {:error, reason} ->
        {:noreply, put_toast(socket, :error, "Could not remove resource: #{inspect(reason)}")}
    end
  end

  def handle_event("remove_skill_resource", _params, socket), do: {:noreply, socket}

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
          |> persist_references(skill, uploaded)
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

  # One dispatch writes the file, registers its document row and tags it public. The
  # returned document id — not the path — is what gets stored on the skill.
  defp upload_resource(skill, volume, tmp_path, entry) do
    destination = Resources.destination(skill, entry.client_name)

    # Both failure shapes are already `{:error, reason}`, so they fall through as-is.
    with {:ok, binary} <- File.read(tmp_path),
         {:ok, %{record: record}} <- create_resource_file(volume, destination, binary) do
      {:ok, %{file_id: record.id, name: record.name}}
    end
  end

  defp create_resource_file(volume, destination, binary) do
    params = %{
      "volume" => volume,
      "path" => destination,
      "content" => binary,
      "tags" => @resource_tags
    }

    data_source_dispatch(:data_source_create_file, params)
  end

  # Records what was written. The write already succeeded, so a failure here loses the
  # reference but not the file — it stays visible in the ingestion browser.
  defp persist_references(socket, _skill, []), do: socket

  defp persist_references(socket, %Skill{} = skill, uploaded) do
    updated =
      Enum.reduce(uploaded, skill, fn {:ok, %{file_id: file_id}}, acc ->
        %{acc | resources: Resources.add_reference(acc, file_id, @resource_provider)}
      end)

    attrs = %{"resources" => updated.resources}
    event = Event.new(%{id: skill.id, attrs: attrs}, :agent, opts: [action: :agent_skill_updated])

    case node_router().dispatch(event).response do
      {:ok, %{skill: saved}} ->
        socket
        |> assign(:selected_skill, saved)
        |> assign_changeset(Skills.change_skill(saved))
        |> refresh_skills()

      _ ->
        socket
    end
  end

  # The skill row is the index; the datasource supplies the metadata. Listing the volume
  # directory instead would show files this skill does not reference, and would miss any it
  # references from elsewhere.
  defp load_skill_resources(%{assigns: %{selected_skill: %Skill{} = skill}} = socket) do
    assign(socket, :skill_resources, reference_records(skill))
  end

  defp load_skill_resources(socket), do: assign(socket, :skill_resources, [])

  # One dispatch per provider rather than per file.
  defp reference_records(%Skill{} = skill) do
    skill
    |> Resources.references()
    |> Enum.group_by(&Map.get(&1, "provider"), &Map.get(&1, "file_id"))
    |> Enum.flat_map(fn {provider, file_ids} -> list_reference_records(provider, file_ids) end)
  end

  # A degraded ingestion role renders an empty resource list rather than crashing the page.
  defp list_reference_records(provider, file_ids) do
    case data_source_dispatch(:data_source_list_files, %{"file_ids" => file_ids}, provider) do
      {:ok, %RecordPage{records: records}} -> records
      _ -> []
    end
  end

  defp data_source_dispatch(action, params, provider \\ @resource_provider) do
    %{provider: provider, params: params}
    |> Event.new(:channels, opts: [action: action])
    |> node_router().dispatch()
    |> Map.fetch!(:response)
  end

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

  # Deletes exactly the documents this skill referenced, by id. The old path-sweeping
  # approach had to guess which volume held the files, because only a volume-relative root
  # was stored; an id needs no such guess and cannot catch a neighbouring skill's files.
  #
  # Runs *after* the record is deleted. If it fails, the skill is still gone and the files
  # remain visible in the ingestion browser — recoverable. The reverse order could strip a
  # live skill's resources when the record deletion then failed.
  defp delete_skill_resources(_socket, nil), do: []

  defp delete_skill_resources(_socket, %Skill{} = skill) do
    skill
    |> Resources.references()
    |> Enum.map(&delete_reference_file/1)
    |> Enum.reject(&(&1 == :ok))
  end

  defp delete_reference_file(%{"file_id" => file_id, "provider" => provider}) do
    data_source_dispatch(:data_source_delete_file, %{"file_id" => file_id}, provider)
  end

  defp delete_reference_file(_reference), do: :ok

  defp drop_reference(socket, %Skill{} = skill, file_id) do
    attrs = %{"resources" => Resources.remove_reference(skill, file_id)}
    event = Event.new(%{id: skill.id, attrs: attrs}, :agent, opts: [action: :agent_skill_updated])

    case node_router().dispatch(event).response do
      {:ok, %{skill: saved}} ->
        socket
        |> assign(:selected_skill, saved)
        |> assign_changeset(Skills.change_skill(saved))
        |> load_skill_resources()
        |> refresh_skills()
        |> put_toast(:info, "Resource removed.")

      {:error, reason} ->
        put_toast(socket, :error, "Could not remove resource: #{inspect(reason)}")
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

  # An overlay toast, not a BOLayout flash: resources are added with the skill drawer open,
  # and the inline banner renders behind it (`--zaq-z-overlay` outranks the page content).
  # Same reason the ingestion jobs drawer reports through `#ingest-toast`.
  defp put_resource_upload_toast(socket, [], []), do: socket

  defp put_resource_upload_toast(socket, uploaded, []) do
    put_toast(socket, :info, "#{length(uploaded)} resource(s) added.")
  end

  defp put_resource_upload_toast(socket, [], failed) do
    put_toast(socket, :error, "Upload failed: #{upload_failure_reasons(failed)}")
  end

  defp put_resource_upload_toast(socket, uploaded, failed) do
    put_toast(socket, :info, "#{length(uploaded)} resource(s) added. #{length(failed)} failed.")
  end

  defp put_toast(socket, kind, message) do
    assign(socket, :upload_toast, %{kind: kind, message: message})
  end

  defp upload_failure_reasons(failed) do
    failed
    |> Enum.map(fn {:error, reason} -> inspect(reason) end)
    |> Enum.uniq()
    |> Enum.join(", ")
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
