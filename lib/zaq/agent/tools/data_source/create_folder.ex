defmodule Zaq.Agent.Tools.DataSource.CreateFolder do
  @moduledoc """
  ReAct tool: creates a folder on a datasource provider.

  Delegates to Channels through `NodeRouter.dispatch/1`, reusing the
  `:data_source_create_file` action. A folder is created by setting a folder
  MIME type (`application/vnd.google-apps.folder` by default) and omitting
  content — the provider's `create_item` intent then produces a folder rather
  than a file.

  ## Nesting (parent_id, not path)

  Providers like Google Drive have **no filesystem paths** — a folder is nested
  by referencing its parent folder's **id**, sent to the provider as
  `parents: [parent_id]`. To create a folder inside a folder known only by name,
  resolve the name to an id first (e.g. via a list/search tool), then pass that
  id as `parent_id`. Omitting `parent_id` creates the folder at the root.

  Before creating, the tool:

    * validates `parent_id` (when given) via `:data_source_get_file`, failing
      early if the parent does not exist.
    * checks for an existing folder of the same name under the same parent via
      `:data_source_list_files` (scoped with a `folder` + `parent` filter). If
      one already exists it is returned with `status: "exists"` instead of
      creating a duplicate (idempotent).
  """

  use Zaq.Engine.Workflows.Action,
    name: "create_folder",
    output_schema: [
      status: [type: :string, required: false, doc: "\"created\" or \"exists\""],
      record: [type: :any, required: false, doc: "Created or existing folder metadata record"]
    ],
    description: """
    Create a folder on a specific datasource provider.
    To create it inside another folder, pass that folder's id as `parent_id`
    (resolve a name to an id with a list/search tool first) — there are no paths. Returns
    the existing folder if one of the same name already exists under that
    parent, otherwise creates it and returns provider metadata.
    """,
    schema: [
      provider: [type: :string, required: true, doc: "Datasource provider key"],
      name: [type: :string, required: true, doc: "Folder name/title"],
      parent_id: [
        type: :string,
        required: false,
        doc: "Id of the parent folder to create inside; omit for the root"
      ],
      mime_type: [type: :string, required: false, doc: "Optional provider folder MIME type"],
      config_id: [type: :string, required: false, doc: "Optional scoped datasource config id"]
    ]

  alias Zaq.Agent.Tools.DataSourceTool

  # Folder marker used across the jido_connect bridge to distinguish folders
  # from files (see Zaq.Channels.JidoConnectBridge.infer_item_kind/1).
  @folder_mime_type "application/vnd.google-apps.folder"

  @impl Jido.Action

  def run(%{provider: provider, name: name} = params, context) do
    with :ok <- validate_parent(provider, params, context),
         {:ok, siblings} <- list_siblings(provider, params, context) do
      case Enum.find(siblings, &folder_named?(&1, name)) do
        nil -> create_folder(provider, params, context)
        existing -> {:ok, %{status: "exists", record: existing}}
      end
    end
  end

  defp validate_parent(provider, %{parent_id: parent_id} = params, context)
       when is_binary(parent_id) and parent_id != "" do
    request =
      %{"file_id" => parent_id}
      |> DataSourceTool.merge_optional(params, [:config_id])
      |> DataSourceTool.wrap_request(provider)

    case DataSourceTool.dispatch(
           :data_source_get_file,
           request,
           context,
           "Data source parent folder lookup failed"
         ) do
      {:ok, _payload} -> :ok
      {:error, _reason} -> {:error, "Parent folder #{inspect(parent_id)} was not found"}
    end
  end

  defp validate_parent(_provider, _params, _context), do: :ok

  defp list_siblings(provider, params, context) do
    # Scope the duplicate scan to folders under the same parent (root when no
    # parent_id), using the bridge's standard list-filter contract.
    filters =
      %{"kind" => "folder"}
      |> DataSourceTool.put_if_present("parent", Map.get(params, :parent_id))

    request =
      %{"filters" => filters}
      |> DataSourceTool.put_many_if_present([{"config_id", Map.get(params, :config_id)}])
      |> DataSourceTool.wrap_request(provider)

    case DataSourceTool.dispatch(
           :data_source_list_files,
           request,
           context,
           "Data source folder listing failed"
         ) do
      {:ok, %{records: records}} when is_list(records) -> {:ok, records}
      {:ok, _payload} -> {:ok, []}
      {:error, _reason} = error -> error
    end
  end

  defp create_folder(provider, params, context) do
    # Force a folder MIME type so create_item produces a folder; nest via the
    # provider's `parents` array (NOT a scalar parent_id, which is ignored).
    folder_mime_type = Map.get(params, :mime_type) || @folder_mime_type

    request =
      %{"mime_type" => folder_mime_type}
      |> DataSourceTool.merge_optional(params, [:name, :config_id])
      |> put_parents(params)
      |> DataSourceTool.wrap_request(provider)

    DataSourceTool.dispatch(
      :data_source_create_file,
      request,
      context,
      "Data source folder creation failed"
    )
  end

  defp put_parents(request, params) do
    case Map.get(params, :parent_id) do
      id when is_binary(id) and id != "" -> Map.put(request, "parents", [id])
      _ -> request
    end
  end

  defp folder_named?(record, name), do: folder?(record) and record_name(record) == name

  defp folder?(record), do: record_field(record, :kind, "kind") in [:folder, "folder"]

  defp record_name(record), do: record_field(record, :name, "name")

  defp record_field(record, atom_key, _string_key)
       when is_map(record) and is_map_key(record, atom_key),
       do: Map.get(record, atom_key)

  defp record_field(record, _atom_key, string_key) when is_map(record),
    do: Map.get(record, string_key)

  defp record_field(_record, _atom_key, _string_key), do: nil
end
