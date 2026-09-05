defmodule ZaqWeb.Live.BO.AI.SkillsLive do
  @moduledoc """
  BO admin page for agent skills.

  Lists, searches (free text + tag), creates, edits, and deletes
  `Zaq.Agent.Skill` records. Reads go straight to `Zaq.Agent.Skills`; mutations
  that affect live agent runtimes (update, delete) are dispatched through
  `NodeRouter` with the `:agent_skill_updated` / `:agent_skill_deleted` actions
  so `Zaq.Agent.RuntimeSync` can fan out tool + MCP re-syncs.

  ## Skill resources

  A skill's resource files are uploaded here but stored through the configured data source,
  in a flat `{slug}/` folder below the global Skills resource folder. Every filesystem hop
  goes through `NodeRouter`: the BO node is not guaranteed to have the volume mounted. Path
  derivation is `Zaq.Agent.Skill.Resources`' job, not this module's.

  Uploading requires an explicitly configured Skills resource data-source location.
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
  alias Zaq.Contracts.Record
  alias Zaq.Contracts.Record.Provenance
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.ModalUpload
  alias ZaqWeb.Components.DesignSystem.Table, as: DSTable
  alias ZaqWeb.Components.Drawer
  alias ZaqWeb.Helpers.SizeFormat
  alias ZaqWeb.Live.BO.AI.BOActor

  @reference_extensions ~w(.md .pdf .txt)
  @script_extensions ~w(.js .lua .rs .ex .exs .py .php .exe)
  @resource_types ~w(reference asset script)

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
      |> assign(:resource_type, "reference")
      |> assign(:staged_resource_types, %{})
      |> assign(:skill_resources, [])
      |> assign_volumes()
      # Size and count come from `Skills.Limits`, not from IngestionLive's rails: nothing
      # upstream caps a resource read (Jido's `load_resource/2` is an uncapped `File.read/1`),
      # so a 20 MB reference would be uploadable and then unusable.
      |> allow_upload(:skill_resources,
        accept: :any,
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
      |> assign(:resource_type, "reference")
      |> assign(:staged_resource_types, %{})
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
          |> assign(:form_tool_keys, skill.provided_tool_keys || [])
          |> assign(:form_mcp_endpoint_ids, skill.enabled_mcp_endpoint_ids || [])
          |> assign(:body_preview, true)
          |> assign(:resource_type, "reference")
          |> assign(:staged_resource_types, %{})
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
    {:noreply,
     socket
     |> drop_staged_resources()
     |> assign(:resource_modal, nil)
     |> assign(:resource_type, "reference")}
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

  def handle_event("validate_skill_resource", params, socket) do
    type = resource_type_from_params(params)

    if compatible_resource_type?(socket.assigns, type) do
      {:noreply, assign(socket, :resource_type, type)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_skill_resource", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:skill_resources, ref)
     |> update(:staged_resource_types, &Map.delete(&1, ref))}
  end

  # On a skill that does not exist yet there is nowhere to write: leave the entries in the
  # LiveView's upload buffer and close the modal. They are written by `save_skill/2` once
  # the record — and therefore the destination path — exists. Phoenix garbage-collects
  # unconsumed entries if this LiveView dies, so abandoning the form leaves nothing behind.
  def handle_event("upload_skill_resource", params, %{assigns: %{mode: :new}} = socket) do
    type = resource_type_from_params(params)

    if resource_type_compatible?(socket.assigns.uploads.skill_resources.entries, type) do
      staged =
        socket.assigns.uploads.skill_resources.entries
        |> Enum.map(&{&1.ref, type})
        |> Map.new()

      {:noreply,
       socket
       |> assign(:resource_modal, nil)
       |> assign(:resource_type, type)
       |> assign(:staged_resource_types, Map.merge(socket.assigns.staged_resource_types, staged))}
    else
      {:noreply, put_toast(socket, :error, "Resource type does not match the selected file(s).")}
    end
  end

  def handle_event(
        "upload_skill_resource",
        params,
        %{assigns: %{mode: :edit, selected_skill: %Skill{} = skill}} = socket
      ) do
    entries = socket.assigns.uploads.skill_resources.entries
    type = resource_type_from_params(params)

    cond do
      not Enum.all?(entries, &(&1.progress == 100)) ->
        {:noreply, socket}

      not resource_type_compatible?(entries, type) ->
        {:noreply,
         put_toast(socket, :error, "Resource type does not match the selected file(s).")}

      true ->
        results =
          consume_uploaded_entries(socket, :skill_resources, fn %{path: tmp_path}, entry ->
            {:ok, upload_resource(socket, skill, tmp_path, entry, type)}
          end)

        {uploaded, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

        socket =
          socket
          |> assign(:resource_type, type)
          |> maybe_persist_resource_root(skill, uploaded)
          |> load_skill_resources()
          |> put_resource_upload_toast(uploaded, failed)
          |> maybe_close_resource_modal(uploaded, failed)

        {:noreply, socket}
    end
  end

  def handle_event("upload_skill_resource", _params, socket), do: {:noreply, socket}

  def handle_event("remove_resource", %{"ref" => ref}, socket) do
    {:noreply,
     socket
     |> cancel_upload(:skill_resources, ref)
     |> update(:staged_resource_types, &Map.delete(&1, ref))}
  end

  def handle_event(
        "remove_resource",
        %{"path" => path},
        %{assigns: %{selected_skill: %Skill{} = skill}} = socket
      ) do
    with %{} = resource <- Enum.find(socket.assigns.skill_resources, &(resource_path(&1) == path)),
         {:ok, location} <- resource_location(skill),
         :ok <- delete_resource_record(socket, location, resource) do
      {:noreply,
       socket
       |> load_skill_resources()
       |> put_toast(:info, "Resource removed")}
    else
      {:error, reason} when reason in [:enoent, :not_found] ->
        {:noreply,
         socket |> load_skill_resources() |> put_toast(:info, "Resource already removed")}

      _ ->
        {:noreply, put_toast(socket, :error, "Resource could not be removed")}
    end
  end

  def handle_event("remove_resource", _params, socket), do: {:noreply, socket}

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
    resources = if skill, do: Skills.list_skill_resources(skill), else: []

    event = Event.new(%{id: skill_id}, :agent, opts: [action: :agent_skill_deleted])

    case node_router().dispatch(event).response do
      {:ok, _payload} ->
        socket =
          socket
          |> put_delete_flash(delete_skill_resources(socket, skill, resources))
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
          |> assign(:form_tool_keys, updated.provided_tool_keys || [])
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
    |> Map.put("provided_tool_keys", socket.assigns.form_tool_keys)
    |> Map.put("enabled_mcp_endpoint_ids", socket.assigns.form_mcp_endpoint_ids)
    |> Map.update("tags", [], &parse_tags/1)
    |> Map.update("allowed_tools", [], &parse_allowed_tools/1)
    |> Map.update("metadata", %{}, &parse_metadata/1)
    |> Map.update("active", true, &(&1 in [true, "true", "on"]))
  end

  defp parse_metadata(value) when is_binary(value) do
    value
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, "=", parts: 2) do
        [key, val] -> Map.put(acc, String.trim(key), String.trim(val))
        [key] -> Map.put(acc, String.trim(key), "")
      end
    end)
    |> Map.reject(fn {key, _value} -> key == "" end)
  end

  defp parse_metadata(value) when is_map(value), do: value
  defp parse_metadata(_value), do: %{}

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
    configured? = match?({:ok, _location}, resource_location(resource_target(socket.assigns)))

    socket
    |> assign(:volumes, %{})
    |> assign(:volumes_connected?, configured?)
    |> assign(:resource_volume, nil)
  end

  # Resources need a destination, and the destination needs a name. A saved skill always
  # has one; an unsaved one has whatever is currently typed into the form.
  defp can_add_resources?(assigns),
    do: resource_destination_available?(assigns) and resource_location_available?(assigns)

  defp resource_destination_available?(%{mode: :edit, selected_skill: %Skill{}}), do: true
  defp resource_destination_available?(%{mode: :new, form: form}), do: present?(form[:name].value)
  defp resource_destination_available?(_assigns), do: false

  defp resource_location_available?(assigns),
    do: match?({:ok, _location}, resource_location(resource_target(assigns)))

  defp resource_unavailable_message(assigns) do
    if resource_destination_available?(assigns) and not resource_location_available?(assigns) do
      "Connect a Skills resource folder in System Config to add resources."
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_), do: false

  # The skill a destination path is derived from: the saved record when editing, or a
  # stand-in carrying the typed name when creating. Nothing is written from the stand-in —
  # it only renders the path preview in the modal.
  defp resource_target(%{mode: :edit, selected_skill: %Skill{} = skill}), do: skill
  defp resource_target(%{form: form}), do: %Skill{name: form[:name].value}
  defp resource_target(_assigns), do: %Skill{}

  # Writes entries staged while the skill did not exist. Returns the `{uploaded, failed}`
  # split so the caller can both flash and decide whether to persist `resource_root`.
  defp flush_staged_resources(socket, %Skill{} = skill) do
    entries = socket.assigns.uploads.skill_resources.entries

    if entries != [] and Enum.all?(entries, &(&1.progress == 100)) do
      socket
      |> consume_uploaded_entries(:skill_resources, fn %{path: tmp_path}, entry ->
        type =
          Map.get(socket.assigns.staged_resource_types, entry.ref, socket.assigns.resource_type)

        {:ok, upload_resource(socket, skill, tmp_path, entry, type)}
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

  defp upload_resource(socket, skill, tmp_path, entry, type) do
    with {:ok, location} <- resource_location(skill),
         {:ok, parent_path} <- provider_path(location, references_dir(skill)),
         {:ok, binary} <- File.read(tmp_path),
         {:ok, %{record: record}} <-
           data_source_action(
             :data_source_create_file,
             %{
               "provider" => location.provider,
               "config_id" => to_string(location.config_id),
               "scope_id" => location.scope_id,
               "path" => parent_path,
               "name" => entry.client_name,
               "content" => Base.encode64(binary),
               "encoding" => "base64"
             },
             socket
           ) do
      with {:ok, resource} <- persist_skill_resource(skill, record, entry, type) do
        {:ok, {record, location, resource}}
      end
    end
  end

  defp resource_location(%Skill{} = skill), do: Skills.resource_location(skill)

  defp provider_path(location, relative_path) do
    [location.folder_path || location.scope_id || "", relative_path]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Path.join()
    |> then(&{:ok, &1})
  end

  # Written once, on the first successful upload, and never recomputed — a later rename
  # must not strand files already sitting under the original root.
  defp maybe_persist_resource_root(
         socket,
         %Skill{} = skill,
         [{:ok, {_record, location, _resource}} | _] = uploaded
       ) do
    persist_resource_location(socket, skill, location, uploaded)
  end

  defp maybe_persist_resource_root(socket, _skill, _uploaded), do: socket

  defp persist_resource_location(socket, skill, location, _uploaded) do
    attrs =
      %{}
      |> maybe_put_resource_location(skill, location)

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

  defp maybe_put_resource_location(attrs, skill, %{pinned?: true})
       when not is_nil(skill.resource_root),
       do: attrs

  defp maybe_put_resource_location(attrs, skill, location) do
    Map.merge(attrs, %{
      "resource_provider" => location.provider,
      "resource_config_id" => location.config_id,
      "resource_scope_id" => location.scope_id,
      "resource_folder_id" => location.folder_id,
      "resource_folder_path" => location.folder_path,
      "resource_root" => Resources.default_root(skill)
    })
  end

  defp persist_skill_resource(%Skill{} = skill, record, entry, type) do
    Skills.upsert_skill_resource(skill, %{
      provider_resource_id: provider_resource_id(record),
      name: Path.basename(entry.client_name),
      resource_type: type,
      size: record.size || 0,
      mime_type: record.mime_type,
      modified_at: record.modified_at
    })
  end

  defp provider_resource_id(%{attributes: %{"provider_record_id" => id}}) when is_binary(id),
    do: id

  defp provider_resource_id(%{id: id}), do: id

  defp load_skill_resources(%{assigns: %{selected_skill: %Skill{} = skill}} = socket) do
    assign(socket, :skill_resources, Skills.list_skill_resources(skill))
  end

  # No skill selected, or no volume to read from (nothing configured, or the data-source node
  # did not answer). Guard rather than let a degraded data-source path crash the page.
  defp load_skill_resources(socket), do: assign(socket, :skill_resources, [])

  defp references_dir(%Skill{} = skill), do: Resources.references_dir(skill)

  # Shown in the upload modal so the operator can see where the file will land in the
  # storage browser before committing to it. Template-facing.
  defp resource_destination(assigns), do: references_dir(resource_target(assigns))

  defp resource_type_options do
    [
      {"Reference", "reference"},
      {"Asset", "asset"},
      {"Script", "script"}
    ]
  end

  defp resource_type_from_params(params) do
    params
    |> Map.get("resource_type")
    |> Resources.normalize_resource_type()
  end

  defp resource_type_description("asset"),
    do: "Files the agent should use, such as templates."

  defp resource_type_description("script"), do: "Executable files the agent can run."

  defp resource_type_description(_type), do: "Additional information the agent should know."

  defp compatible_resource_type?(assigns, type), do: type in compatible_resource_types(assigns)

  defp compatible_resource_types(assigns) do
    assigns.uploads.skill_resources.entries
    |> Enum.map(&compatible_resource_types_for_entry/1)
    |> Enum.reduce(@resource_types, fn types, acc -> Enum.filter(acc, &(&1 in types)) end)
  end

  defp resource_type_compatible?(entries, type),
    do: Enum.all?(entries, &(type in compatible_resource_types_for_entry(&1)))

  defp compatible_resource_types_for_entry(entry) do
    case resource_extension(entry) do
      extension when extension in @reference_extensions -> ["reference", "asset"]
      extension when extension in @script_extensions -> ["asset", "script"]
      _extension -> ["asset"]
    end
  end

  defp resource_extension(%{client_name: name}) when is_binary(name),
    do: name |> Path.extname() |> String.downcase(:ascii)

  defp resource_extension(_entry), do: ""

  defp staged_resource_type(assigns, entry) do
    assigns.staged_resource_types
    |> Map.get(entry.ref, assigns.resource_type)
    |> resource_type_label()
  end

  defp persisted_resource_type(_skill, %{resource_type: _type} = resource) do
    resource
    |> Map.get(:resource_type)
    |> resource_type_label()
  end

  defp persisted_resource_type(_skill, _resource), do: resource_type_label(nil)

  defp resource_type_label("asset"), do: "Asset"
  defp resource_type_label("script"), do: "Script"
  defp resource_type_label(_type), do: "Reference"

  defp resource_path(%{name: name}) when is_binary(name), do: Path.basename(name)
  defp resource_path(%{"name" => name}) when is_binary(name), do: Path.basename(name)
  defp resource_path(%{path: path}) when is_binary(path), do: Path.basename(path)
  defp resource_path(%{"path" => path}) when is_binary(path), do: Path.basename(path)
  defp resource_path(_resource), do: ""

  defp resource_dom_id(resource) do
    resource
    |> resource_path()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
  end

  # Template-facing wrapper — the button's visibility gate.
  defp resources_addable?(assigns), do: can_add_resources?(assigns)

  defp resource_destination_available_for_template?(assigns),
    do: resource_destination_available?(assigns)

  defp resource_upload_hint(type) do
    extensions = resource_accept_label(type)
    max = SizeFormat.format_size(Limits.get(:resource_max_bytes))

    "#{extensions} — max #{max}"
  end

  defp resource_accept_label("asset"), do: "Any file"
  defp resource_accept_label("script"), do: Enum.join(@script_extensions, " ")
  defp resource_accept_label(_type), do: Enum.join(@reference_extensions, " ")

  defp resource_input_accept("asset"), do: nil
  defp resource_input_accept("script"), do: Enum.join(@script_extensions, ",")
  defp resource_input_accept(_type), do: Enum.join(@reference_extensions, ",")

  # Removes a deleted skill's whole resource directory.
  #
  # The volume is swept rather than looked up: the upload modal lets the operator choose a
  # volume, but only the volume-relative `resource_root` is persisted, so which volume
  # holds the files is not recoverable from the skill. Sweeping is safe because the root is
  # namespaced per skill, and volumes without the directory are skipped.
  #
  # Runs *after* the record is deleted. If it fails, the skill is still gone and the files
  # remain visible in the storage browser — recoverable. The reverse order could strip a
  # live skill's resources when the record deletion then failed.
  defp delete_skill_resources(_socket, nil, _resources), do: []

  defp delete_skill_resources(socket, %Skill{} = skill, resources) do
    case resource_location(skill) do
      {:ok, location} ->
        resources
        |> Enum.map(&delete_resource_record(socket, location, &1, false))
        |> Enum.reject(&(&1 == :absent))

      {:error, :skill_resource_location_not_configured} ->
        []

      {:error, reason} when reason in [:enoent, :not_found, :not_a_directory] ->
        []

      _ ->
        [{:error, :resource_cleanup_failed}]
    end
  end

  # A skill that never had a resource uploaded has no directory. Missing paths are absent,
  # but real delete failures still surface so the operator knows cleanup was partial.
  defp delete_resource_record(socket, location, record) do
    delete_resource_record(socket, location, record, true)
  end

  defp delete_resource_record(socket, location, record, delete_row?) do
    source_record = signed_resource_record(location, record)
    delete_source_record(socket, location, record, source_record, delete_row?)
  end

  defp signed_resource_record(location, resource) do
    record = %Record{
      id: resource.provider_resource_id,
      kind: :file,
      name: resource.name,
      mime_type: resource.mime_type,
      size: resource.size,
      attributes: %{"provider_record_id" => resource.provider_resource_id}
    }

    {:ok, sealed} =
      Provenance.seal(record, %{
        "provider" => location.provider,
        "config_id" => to_string(location.config_id),
        "provider_record_id" => resource.provider_resource_id
      })

    sealed
  end

  defp delete_source_record(socket, location, resource, source_record, delete_row?) do
    case data_source_delete_action(location, source_record, socket) do
      {:ok, %{status: "deleted"}} ->
        maybe_delete_resource_row(resource, delete_row?)

      {:error, reason} when reason in [:enoent, :not_found] ->
        :absent

      other ->
        other
    end
  end

  defp maybe_delete_resource_row(_resource, false), do: :ok

  defp maybe_delete_resource_row(resource, true) do
    case Skills.delete_skill_resource(resource) do
      {:ok, _resource} -> :ok
      other -> other
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

  defp data_source_action(action, params, socket) do
    event =
      Event.new(
        %{provider: params["provider"], params: Map.delete(params, "provider")},
        :channels,
        opts: [action: action, data_source_bridge_module: data_source_bridge_module()],
        actor: resource_actor(socket)
      )

    node_router().dispatch(event).response
  end

  defp data_source_delete_action(location, record, socket) do
    event =
      Event.new(%{record: record}, :channels,
        opts: [
          action: :data_source_delete_file,
          data_source_bridge_module: data_source_bridge_module(),
          data_source_provider: location.provider,
          data_source_config_id: location.config_id
        ],
        actor: resource_actor(socket)
      )

    node_router().dispatch(event).response
  end

  defp resource_actor(%{assigns: assigns}), do: BOActor.build(Map.get(assigns, :current_user))

  defp data_source_bridge_module do
    Application.get_env(
      :zaq,
      :skills_live_data_source_bridge_module,
      Zaq.Channels.DataSourceBridge
    )
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
    |> assign(:resource_type, "reference")
    |> assign(:staged_resource_types, %{})
    |> assign(:skill_resources, [])
    |> assign_changeset(Skills.change_skill(%Skill{}))
  end

  # Abandoning the form must not leave staged entries to be flushed into whatever skill is
  # created or selected next.
  defp drop_staged_resources(socket) do
    socket.assigns.uploads.skill_resources.entries
    |> Enum.reduce(socket, fn entry, acc -> cancel_upload(acc, :skill_resources, entry.ref) end)
    |> assign(:staged_resource_types, %{})
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

  defp metadata_to_string(metadata) when is_map(metadata) do
    metadata
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> "#{key}=#{value}" end)
  end

  defp metadata_to_string(_metadata), do: ""

  defp field_errors(%Phoenix.HTML.FormField{errors: errors}) do
    Enum.map(errors, &ZaqWeb.CoreComponents.translate_error/1)
  end
end
