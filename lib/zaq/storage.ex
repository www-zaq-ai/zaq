defmodule Zaq.Storage do
  @moduledoc """
  Storage role context for mounted-volume filesystem operations.

  This role owns bytes, directory metadata, volume mutation, and source-scoped
  access policy. Ingestion consumes records produced by storage-backed data
  sources, but it does not manage mounted files directly.
  """

  alias Zaq.Accounts.People
  alias Zaq.Channels.ChannelConfig
  alias Zaq.Identity.ActorNormalizer
  alias Zaq.Materialization.Handle
  alias Zaq.Permissions
  alias Zaq.Repo
  alias Zaq.Storage.EntryCatalog
  alias Zaq.Storage.FileExplorer
  alias Zaq.Storage.FileExplorer.Entry
  alias Zaq.Storage.SourcePath
  alias Zaq.Storage.StorageEntry
  alias Zaq.Storage.VolumeConfig
  alias Zaq.Utils.Map, as: MapUtils

  @textual_mime_types ~w(
    application/json application/xml application/javascript
    application/yaml application/x-yaml application/x-sh
  )

  @doc "Returns configured storage volumes as `%{name => abs_path}`."
  def list_volumes(opts \\ []), do: file_explorer(opts).list_volumes(opts)

  @doc "Returns true when at least one volume is explicitly configured."
  def volumes_configured?(opts \\ []), do: file_explorer(opts).volumes_configured?(opts)

  @doc "Lists entries in a volume directory."
  def list_entries(volume_name, path, opts \\ []),
    do: file_explorer(opts).list(volume_name, path, opts)

  @doc "Returns metadata for one storage entry."
  def file_info(volume_name, path, opts \\ [])
  def file_info(nil, path, opts), do: file_explorer(opts).file_info(path, opts)

  def file_info(volume_name, path, opts),
    do: file_explorer(opts).file_info(volume_name, path, opts)

  @doc "Creates a directory in a volume."
  def create_directory(volume_name, path, opts \\ []),
    do: file_explorer(opts).create_directory(volume_name, path, opts)

  @doc "Writes a file without deduplicating the path."
  def save_file(volume_name, path, content, opts \\ []),
    do: file_explorer(opts).upload(volume_name, path, content, opts)

  @doc "Writes a file, deduplicating the path when a file already exists."
  def upload_file(volume_name, path, content, opts \\ []),
    do: file_explorer(opts).upload_unique(volume_name, path, content, opts)

  @doc "Deletes a file."
  def delete_file(volume_name, path, opts \\ []),
    do: file_explorer(opts).delete(volume_name, path, opts)

  @doc "Deletes a directory recursively."
  def delete_directory(volume_name, path, opts \\ []),
    do: file_explorer(opts).delete_directory(volume_name, path, opts)

  @doc "Renames or moves a storage entry inside one volume."
  def rename_entry(volume_name, old_path, new_path, opts \\ []),
    do: file_explorer(opts).rename(volume_name, old_path, new_path, opts)

  @doc "Resolves a volume-relative path to an absolute path."
  def resolve_path(volume_name, path, opts \\ []),
    do: file_explorer(opts).resolve_path(volume_name, path, opts)

  @doc "Returns the storage entry for a source locator."
  @spec describe_document(String.t()) :: {:ok, Entry.t()} | {:error, term()}
  def describe_document(source, opts \\ []) do
    with {:ok, opts} <- disk_config_opts(%{}, opts) do
      entry_from_source(source, opts)
    end
  end

  @doc "Returns storage entries as a page-shaped map consumed by DiskBridge."
  @spec list_documents(map()) :: {:ok, map()} | {:error, term()}
  def list_documents(params \\ %{}, opts \\ []) when is_map(params) do
    with {:ok, opts} <- disk_config_opts(params, opts) do
      cond do
        parent = parent_source(params) ->
          list_directory_entries(split_parent(parent, opts), params, opts)

        root_path?(params) ->
          list_all_volume_entries(params, opts)

        true ->
          list_volume_roots(params, opts)
      end
    end
  end

  @doc "Writes a new storage file and returns its entry."
  @spec persist_document(map()) :: {:ok, map()} | {:error, term()}
  def persist_document(request, opts \\ []) when is_map(request) do
    with {:ok, opts} <- disk_config_opts(request, opts),
         {:ok, {volume_name, dir}} <- destination(request, opts),
         :ok <- authorize_create_in_parent(volume_name, dir, opts),
         {:ok, name} <- required(request, "name", :name_required),
         {:ok, content} <- decode_content(request),
         dest = dir |> Path.join(name) |> SourcePath.normalize_relative(),
         {:ok, _absolute_path} <- upload_file(volume_name, dest, content, opts),
         {:ok, entry} <- file_info(volume_name, dest, opts) do
      {:ok, %{status: "created", entry: entry}}
    end
  end

  @doc "Creates a storage directory and returns its entry."
  @spec persist_directory(map()) :: {:ok, map()} | {:error, term()}
  def persist_directory(request, opts \\ []) when is_map(request) do
    with {:ok, opts} <- disk_config_opts(request, opts),
         {:ok, {volume_name, dir}} <- destination(request, opts),
         :ok <- authorize_create_in_parent(volume_name, dir, opts),
         {:ok, name} <- required(request, "name", :name_required),
         dest = dir |> Path.join(name) |> SourcePath.normalize_relative(),
         :ok <- create_directory(volume_name, dest, opts),
         {:ok, entry} <- file_info(volume_name, dest, opts) do
      {:ok, %{status: "created", entry: entry}}
    end
  end

  @doc "Reads a storage file's bytes."
  @spec materialize_document(map()) :: {:ok, map()} | {:error, term()}
  def materialize_document(request, opts \\ []) when is_map(request) do
    with {:ok, opts} <- disk_config_opts(request, opts),
         {:ok, source} <- required(request, "file_id", :file_id_required) do
      materialize_source(source, request, opts)
    end
  end

  @doc "Updates content, name, or parent directory for a storage file."
  @spec update_document(map()) :: {:ok, map()} | {:error, term()}
  def update_document(request, opts \\ []) when is_map(request) do
    with {:ok, opts} <- disk_config_opts(request, opts),
         {:ok, file_id} <- required(request, "file_id", :file_id_required),
         {:ok, {volume_name, path}} <- resolve_entry_ref(file_id, opts),
         {:ok, %Entry{} = current_entry} <- file_info(volume_name, path, opts),
         :ok <- authorize_entry(current_entry, :update, opts),
         {:ok, target} <- move_target(volume_name, path, request, opts),
         :ok <- authorize_move_destination(volume_name, path, target, opts),
         :ok <- write_content(volume_name, path, request, opts),
         :ok <- move(volume_name, path, target, opts),
         {:ok, entry} <- file_info(volume_name, target, opts) do
      {:ok, %{status: "updated", entry: entry}}
    end
  end

  @doc "Deletes the storage entry named by source."
  @spec delete_document(String.t() | map()) :: {:ok, map()} | {:error, term()}
  def delete_document(file_id_or_request, opts \\ [])

  def delete_document(%{} = request, opts) do
    with {:ok, opts} <- disk_config_opts(request, opts),
         {:ok, file_id} <- required(request, "file_id", :file_id_required) do
      delete_document(file_id, opts)
    end
  end

  def delete_document(file_id, opts) when is_binary(file_id) do
    with {:ok, {volume_name, path}} <- resolve_entry_ref(file_id, opts),
         {:ok, %Entry{type: type} = entry} <- file_info(volume_name, path, opts),
         :ok <- authorize_entry(entry, :delete, opts),
         :ok <- delete_entry(volume_name, path, type, opts) do
      {:ok, %{status: "deleted"}}
    end
  end

  @doc "Lists source-scoped grants for a storage entry."
  @spec list_document_grants(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def list_document_grants(file_id, opts \\ []) when is_binary(file_id) do
    catalog = entry_catalog(opts)
    permissions = permissions(opts)

    with %EntryCatalog{} = entry <- catalog.by_id(file_id) || {:error, :not_found} do
      ancestors = entry_ancestor_resources(entry.id, opts)

      grants =
        entry.id
        |> storage_resource()
        |> permissions.list_effective(Keyword.put(opts, :ancestors, ancestors))
        |> Enum.map(&permission_grant(&1, opts))

      {:ok,
       %{
         effective_permissions: grants
       }}
    end
  end

  @doc "Grants source-scoped access to a storage entry."
  @spec grant_document_access(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def grant_document_access(file_id, attrs, opts \\ []) when is_binary(file_id) and is_map(attrs),
    do: file_id |> storage_resource() |> permissions(opts).grant(attrs)

  @doc "Replaces direct source-scoped grants for a storage entry."
  @spec replace_document_grants(String.t(), [map()], keyword()) :: {:ok, map()} | {:error, term()}
  def replace_document_grants(file_id, grants, opts \\ [])
      when is_binary(file_id) and is_list(grants) do
    catalog = entry_catalog(opts)

    with %EntryCatalog{} = entry <- catalog.by_id(file_id) || {:error, :not_found},
         :ok <- authorize_manage_entry(entry, opts),
         {:ok, _direct} <-
           permissions(opts).replace(
             storage_resource(file_id),
             normalize_grants(grants, opts),
             opts
           ) do
      affected_ids = [file_id | Enum.map(catalog.descendants(file_id), & &1.id)]
      {:ok, %{status: "updated", file_id: file_id, affected_file_ids: affected_ids}}
    end
  end

  @doc "Searches storage entries by filename across mounted volumes."
  @spec search_documents(map()) :: {:ok, map()} | {:error, term()}
  def search_documents(params, opts \\ []) when is_map(params) do
    with {:ok, opts} <- disk_config_opts(params, opts),
         {:ok, query} <- required(params, "query", :query_required) do
      query = String.downcase(query)

      entries =
        list_volumes(opts)
        |> Enum.flat_map(fn {volume, _root} -> search_volume(volume, ".", query, opts) end)
        |> Enum.filter(&can_read_entry?(&1, opts))
        |> Enum.take(100)

      {:ok, entry_page(entries, length(entries))}
    end
  end

  @doc "Reports mounted storage volume counts."
  @spec volume_stats() :: {:ok, map()}
  def volume_stats(opts \\ []) do
    with {:ok, opts} <- disk_config_opts(%{}, opts) do
      volumes = list_volumes(opts)

      entries =
        Enum.flat_map(volumes, fn {volume, _root} -> search_volume(volume, ".", "", opts) end)

      principal_resources = principal_count_resources(volumes, entries, opts)

      {:ok,
       %{
         files_count: Enum.count(entries, &(&1.type == :file)),
         folders_count: Enum.count(entries, &(&1.type == :directory)),
         principals_count: permissions(opts).count_principals(principal_resources),
         root_folders: volumes |> Map.keys() |> Enum.sort()
       }}
    end
  end

  defp principal_count_resources(volumes, entries, opts) do
    root_resources =
      Enum.map(volumes, fn {volume, _root} -> catalog_volume_root(volume, opts) end)

    (root_resources ++ entries)
    |> Enum.flat_map(fn
      %{id: id, parent_id: parent_id} -> [id, parent_id]
      %{id: id} -> [id]
      _entry -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&storage_resource/1)
  end

  defp list_volume_roots(params, opts) do
    with {:ok, volumes} <- existing_volume_roots(opts) do
      entries =
        Enum.map(volumes, fn {volume, stat} ->
          catalog_entry = catalog_volume_root(volume, opts)

          %Entry{
            id: catalog_entry.id,
            parent_id: catalog_entry.parent_id,
            name: volume,
            type: :directory,
            size: stat.size,
            modified_at: stat.mtime |> DateTime.from_unix!(),
            volume: volume,
            relative_path: ".",
            source: volume
          }
        end)

      entries
      |> Enum.sort_by(& &1.name)
      |> paginate_entries(nil, ".", params, opts)
    end
  end

  defp list_all_volume_entries(params, opts) do
    with {:ok, volumes} <- existing_volume_roots(opts),
         {:ok, entries} <- list_volume_entries(volumes, opts) do
      paginate_entries(entries, nil, "/", params, opts)
    end
  end

  defp existing_volume_roots(opts) do
    list_volumes(opts)
    |> Enum.reduce_while({:ok, []}, fn {volume, root}, {:ok, volumes} ->
      case File.stat(root, time: :posix) do
        {:ok, %{type: :directory} = stat} ->
          {:cont, {:ok, [{volume, stat} | volumes]}}

        {:ok, _stat} ->
          {:halt, {:error, {:volume_unavailable, volume, :not_a_directory}}}

        {:error, :enoent} ->
          {:cont, {:ok, volumes}}

        {:error, reason} ->
          {:halt, {:error, {:volume_unavailable, volume, reason}}}
      end
    end)
  end

  defp list_volume_entries(volumes, opts) do
    Enum.reduce_while(volumes, {:ok, []}, fn {volume, _stat}, {:ok, entries} ->
      case list_entries(volume, ".", opts) do
        {:ok, volume_entries} ->
          {:cont, {:ok, volume_entries ++ entries}}

        {:error, reason} ->
          {:halt, {:error, {:volume_unavailable, volume, reason}}}
      end
    end)
  end

  defp catalog_volume_root(volume, opts) do
    case entry_catalog(opts).ensure(volume, ".", :directory) do
      {:ok, entry} -> entry
      {:error, _reason} -> %{id: nil, parent_id: nil}
    end
  end

  defp list_directory_entries({volume_name, path}, params, opts) do
    with {:ok, entries} <- list_entries(volume_name, path, opts) do
      paginate_entries(entries, volume_name, path, params, opts)
    end
  end

  defp entry_page(entries, scanned), do: %{entries: entries, scanned: scanned}

  defp entry_page(entries, scanned, pagination),
    do: %{entries: entries, scanned: scanned, pagination: pagination}

  defp paginate_entries(entries, volume_name, path, params, opts) do
    with {:ok, page_size} <- page_size(params),
         {:ok, last_source} <- cursor_source(params, volume_name, path) do
      ordered = entries |> Enum.filter(&can_read_entry?(&1, opts)) |> Enum.sort_by(& &1.source)

      filtered =
        if last_source, do: Enum.filter(ordered, &(&1.source > last_source)), else: ordered

      page_entries = Enum.take(filtered, page_size + 1)
      returned = Enum.take(page_entries, page_size)
      has_more? = length(page_entries) > page_size

      cursor =
        if has_more? do
          returned
          |> List.last()
          |> then(&issue_cursor(volume_name, path, &1.source))
        end

      page =
        entry_page(returned, length(entries), %{
          cursor: cursor,
          has_more?: has_more?,
          page_size: page_size,
          pages_loaded: nil,
          truncated?: false
        })

      {:ok, maybe_put_permissions(page, params, opts)}
    end
  end

  defp maybe_put_permissions(%{entries: entries} = page, params, opts) do
    if MapUtils.present_value(params, "include_permissions") == true do
      Map.put(
        page,
        :permissions_by_id,
        Map.new(entries, &{&1.id, permissions_for_entry(&1, opts)})
      )
    else
      page
    end
  end

  defp permissions_for_entry(%Entry{id: id}, opts) when is_binary(id) do
    ancestors = entry_ancestor_resources(id, opts)

    id
    |> storage_resource()
    |> permissions(opts).list_effective(Keyword.put(opts, :ancestors, ancestors))
    |> Enum.map(&permission_grant(&1, opts))
    |> Enum.map(fn grant ->
      %{
        id: grant.id,
        type: grant.type,
        target_id: grant.target_id,
        name: grant.name,
        access_rights: grant.access_rights,
        inherited?: Map.get(grant, :inherited?, false),
        origin_resource_id: Map.get(grant, :origin_resource_id)
      }
    end)
  end

  defp permissions_for_entry(_entry, _opts), do: []

  defp page_size(params) do
    raw = MapUtils.present_value(params, "page_size") || 100

    case raw do
      value when is_integer(value) and value > 0 -> {:ok, min(value, 500)}
      value when is_binary(value) -> parse_page_size(value)
      _ -> {:error, :invalid_page_size}
    end
  end

  defp parse_page_size(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, min(integer, 500)}
      _ -> {:error, :invalid_page_size}
    end
  end

  defp cursor_source(params, volume_name, path) do
    case MapUtils.present_value(params, "page_token") do
      nil ->
        {:ok, nil}

      token ->
        with {:ok, %{type: "storage_page_cursor", locator: locator}} <- Handle.verify(token),
             true <-
               Map.get(locator, "volume") == volume_name || {:error, :cursor_context_mismatch},
             true <- Map.get(locator, "path") == path || {:error, :cursor_context_mismatch},
             source when is_binary(source) <- Map.get(locator, "source") do
          {:ok, source}
        else
          {:ok, _other} -> {:error, :invalid_page_token}
          {:error, reason} -> {:error, reason}
          _ -> {:error, :invalid_page_token}
        end
    end
  end

  defp issue_cursor(volume_name, path, source) do
    {:ok, token} =
      Handle.issue("storage_page_cursor", %{
        "volume" => volume_name,
        "path" => path,
        "source" => source
      })

    token
  end

  defp entry_from_source(source, opts) do
    with {:ok, {volume_name, path}} <- resolve_entry_ref(source, opts),
         {:ok, %Entry{} = entry} <- file_info(volume_name, path, opts),
         :ok <- authorize_entry(entry, :read, opts) do
      {:ok, entry}
    end
  end

  defp materialize_source(source, request, opts) do
    with {:ok, {volume_name, path}} <- resolve_entry_ref(source, opts),
         {:ok, %Entry{} = entry} <- file_info(volume_name, path, opts),
         :ok <- authorize_entry(entry, :read, opts),
         {:ok, absolute_path} <- resolve_path(volume_name, entry.relative_path, opts),
         {:ok, binary} <- File.read(absolute_path) do
      {:ok, content_answer(entry, binary, request, opts)}
    end
  end

  defp disk_config_opts(request, opts) do
    cond do
      Keyword.has_key?(opts, :storage_config) ->
        {:ok, opts}

      config_id = disk_config_id(request, opts) ->
        with {:ok, config} <- fetch_enabled_disk_config(config_id),
             {:ok, storage_opts} <- VolumeConfig.opts_for_channel_config(config, opts) do
          {:ok, Keyword.merge(opts, storage_opts)}
        end

      true ->
        with {:ok, config} <- fetch_single_enabled_disk_config(),
             {:ok, storage_opts} <- VolumeConfig.opts_for_channel_config(config, opts) do
          {:ok, Keyword.merge(opts, storage_opts)}
        end
    end
  end

  defp fetch_enabled_disk_config(config_id) do
    with {:ok, id} <- parse_config_id(config_id),
         %ChannelConfig{provider: "disk", kind: "data_source", enabled: true} = config <-
           Repo.get(ChannelConfig, id) do
      {:ok, config}
    else
      _ -> {:error, :disk_channel_config_not_found}
    end
  end

  defp disk_config_id(request, opts) do
    MapUtils.present_value(request, "config_id") || Keyword.get(opts, :config_id)
  end

  defp fetch_single_enabled_disk_config do
    case ChannelConfig.list_enabled_by_kind(:data_source, ["disk"]) do
      [config] -> {:ok, config}
      [] -> {:error, :disk_channel_config_not_found}
      _configs -> {:error, :ambiguous_disk_channel_config}
    end
  end

  defp parse_config_id(id) when is_integer(id), do: {:ok, id}

  defp parse_config_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {integer, ""} -> {:ok, integer}
      _ -> {:error, :invalid_disk_channel_config_id}
    end
  end

  defp parse_config_id(_id), do: {:error, :invalid_disk_channel_config_id}

  defp resolve_entry_ref(ref, opts) when is_binary(ref) do
    with true <- dashed_uuid?(ref),
         {:ok, _uuid} <- Ecto.UUID.cast(ref),
         %EntryCatalog{volume: volume, relative_path: path} <- entry_catalog(opts).by_id(ref) do
      {:ok, {volume, path}}
    else
      _ -> {:ok, SourcePath.split_source(ref, nil, nil, opts)}
    end
  end

  defp dashed_uuid?(ref),
    do:
      String.match?(
        ref,
        ~r/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
      )

  defp content_answer(%Entry{} = entry, binary, request, opts) do
    if base64?(entry, binary, request, opts) do
      %{content: Base.encode64(binary), encoding: "base64"}
    else
      %{content: binary, encoding: nil}
    end
  end

  defp base64?(%Entry{name: name}, binary, request, opts) do
    MapUtils.present_value(request, "encoding") == "base64" or
      not (textual_mime?(mime(opts).from_path(name)) and String.valid?(binary))
  end

  defp textual_mime?(mime) when is_binary(mime),
    do: String.starts_with?(mime, "text/") or mime in @textual_mime_types

  defp textual_mime?(_), do: false

  defp write_content(volume_name, path, request, opts) do
    case MapUtils.present_value(request, "content") do
      nil ->
        :ok

      _content ->
        with {:ok, content} <- decode_content(request),
             {:ok, _absolute_path} <- save_file(volume_name, path, content, opts) do
          :ok
        end
    end
  end

  defp move_target(volume_name, path, request, opts) do
    name = MapUtils.present_value(request, "name") || Path.basename(path)

    case MapUtils.present_value(request, "path") do
      nil ->
        {:ok, path |> Path.dirname() |> Path.join(name) |> SourcePath.normalize_relative()}

      new_path ->
        case split_parent(new_path, opts) do
          {^volume_name, dir} -> {:ok, dir |> Path.join(name) |> SourcePath.normalize_relative()}
          {nil, dir} -> {:ok, dir |> Path.join(name) |> SourcePath.normalize_relative()}
          {_other_volume, _dir} -> {:error, :cross_volume_move_unsupported}
        end
    end
  end

  defp move(_volume_name, path, path, _opts), do: :ok

  defp move(volume_name, path, target, opts) do
    case rename_entry(volume_name, path, target, opts) do
      {:ok, _absolute_path} -> :ok
      error -> error
    end
  end

  defp delete_entry(volume_name, path, :directory, opts),
    do: delete_directory(volume_name, path, opts)

  defp delete_entry(volume_name, path, _type, opts), do: delete_file(volume_name, path, opts)

  defp storage_resource(file_id), do: %StorageEntry{id: file_id}

  defp can_read_entry?(%Entry{} = entry, opts) do
    case authorize_entry(entry, :read, opts) do
      :ok -> true
      {:error, :unauthorized} -> false
    end
  end

  defp authorize_entry(%Entry{id: id} = entry, right, opts) when is_binary(id) do
    resource = storage_resource(id)

    cond do
      Keyword.get(opts, :skip_permissions, false) ->
        :ok

      permissions(opts).can?(
        person_from_opts(opts),
        right,
        resource,
        Keyword.put(opts, :ancestors, entry_ancestor_resources(entry.id, opts))
      ) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp authorize_entry(_entry, _right, opts) do
    if Keyword.get(opts, :skip_permissions, false), do: :ok, else: {:error, :unauthorized}
  end

  defp authorize_create_in_parent(volume_name, dir, opts) do
    with {:ok, %Entry{} = parent} <- nearest_existing_entry(volume_name, dir, opts) do
      authorize_entry(parent, :write, opts)
    end
  end

  defp authorize_move_destination(_volume_name, path, path, _opts), do: :ok

  defp authorize_move_destination(volume_name, path, target, opts) do
    if Path.dirname(path) == Path.dirname(target) do
      :ok
    else
      authorize_create_in_parent(volume_name, Path.dirname(target), opts)
    end
  end

  defp nearest_existing_entry(volume_name, dir, opts) do
    normalized = SourcePath.normalize_relative(dir || ".")

    case file_info(volume_name, normalized, opts) do
      {:ok, %Entry{type: :directory} = entry} ->
        {:ok, entry}

      {:ok, %Entry{type: "directory"} = entry} ->
        {:ok, entry}

      {:ok, _entry} ->
        {:error, :not_a_directory}

      {:error, :enoent} ->
        parent = Path.dirname(normalized)

        if parent == normalized do
          {:error, :not_found}
        else
          nearest_existing_entry(volume_name, parent, opts)
        end

      error ->
        error
    end
  end

  defp authorize_manage_entry(%EntryCatalog{id: id}, opts) do
    cond do
      Keyword.get(opts, :skip_permissions, false) ->
        :ok

      permissions(opts).can?(
        person_from_opts(opts),
        :manage,
        storage_resource(id),
        Keyword.put(opts, :ancestors, entry_ancestor_resources(id, opts))
      ) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp person_from_opts(opts) do
    opts
    |> Keyword.get(:actor)
    |> ActorNormalizer.person_id()
    |> People.get_person()
  end

  defp entry_ancestor_resources(entry_id, opts) do
    entry_id
    |> entry_catalog(opts).ancestors()
    |> Enum.map(&storage_resource(&1.id))
  end

  defp normalize_grants(grants, opts) do
    grants
    |> Enum.map(&normalize_grant(&1, opts))
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_grant(%{"type" => "public"}, opts),
    do: %{team_id: permissions(opts).everyone_team_id(), access_rights: ["read"]}

  defp normalize_grant(%{type: "public"}, opts),
    do: %{team_id: permissions(opts).everyone_team_id(), access_rights: ["read"]}

  defp normalize_grant(%{type: :public}, opts),
    do: %{team_id: permissions(opts).everyone_team_id(), access_rights: ["read"]}

  defp normalize_grant(
         %{"type" => "person", "target_id" => id, "access_rights" => rights},
         _opts
       ),
       do: %{person_id: parse_int(id), access_rights: normalize_rights(rights)}

  defp normalize_grant(%{"type" => "team", "target_id" => id, "access_rights" => rights}, _opts),
    do: %{team_id: parse_int(id), access_rights: normalize_rights(rights)}

  defp normalize_grant(%{type: :person, id: id, access_rights: rights}, _opts),
    do: %{person_id: parse_int(id), access_rights: normalize_rights(rights)}

  defp normalize_grant(%{type: :team, id: id, access_rights: rights}, _opts),
    do: %{team_id: parse_int(id), access_rights: normalize_rights(rights)}

  defp normalize_grant(_grant, _opts), do: nil

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_binary(value), do: String.to_integer(value)

  defp normalize_rights(rights) when is_list(rights), do: Enum.map(rights, &to_string/1)
  defp normalize_rights(_rights), do: ["read"]

  defp permission_grant(%{permission: permission, origin: origin, inherited?: inherited?}, opts) do
    permission
    |> permission_grant(opts)
    |> Map.put(:inherited?, inherited?)
    |> Map.put(:origin_resource_id, origin.id)
  end

  defp permission_grant(permission, opts) do
    public? = permission.team_id == permissions(opts).everyone_team_id()

    %{
      id: permission.id,
      type: permission_type(permission, public?),
      target_id: to_string(permission.person_id || permission.team_id),
      name: permission_name(permission, public?),
      access_rights: permission.access_rights || []
    }
  end

  defp permission_type(_permission, true), do: "public"
  defp permission_type(%{person_id: person_id}, false) when not is_nil(person_id), do: "person"
  defp permission_type(_permission, false), do: "team"

  defp permission_name(_permission, true), do: "Public"
  defp permission_name(%{person: %{full_name: name}}, false), do: name
  defp permission_name(%{team: %{name: name}}, false), do: name
  defp permission_name(_permission, false), do: nil

  defp search_volume(volume, path, query, opts) do
    case list_entries(volume, path, opts) do
      {:ok, entries} ->
        matching =
          Enum.filter(
            entries,
            &(query == "" or String.contains?(String.downcase(&1.name), query))
          )

        children =
          entries
          |> Enum.filter(&(&1.type == :directory))
          |> Enum.flat_map(&search_volume(volume, &1.relative_path, query, opts))

        matching ++ children

      {:error, _reason} ->
        []
    end
  end

  defp decode_content(request) do
    content = MapUtils.present_value(request, "content") || ""

    case MapUtils.present_value(request, "encoding") do
      "base64" ->
        case Base.decode64(content) do
          {:ok, binary} -> {:ok, binary}
          :error -> {:error, :invalid_base64}
        end

      _ ->
        {:ok, content}
    end
  end

  defp destination(request, opts) do
    path = MapUtils.present_value(request, "path") || "."

    case split_parent(path, opts) do
      {nil, dir} -> default_destination(dir, opts)
      {volume_name, dir} -> {:ok, {volume_name, dir}}
    end
  end

  defp default_destination(dir, opts) do
    opts
    |> Keyword.get(:storage_config, [])
    |> Keyword.get(:default_volume)
    |> case do
      volume_name when is_binary(volume_name) and volume_name != "" -> {:ok, {volume_name, dir}}
      _ -> {:error, :volume_required}
    end
  end

  defp required(request, key, error) do
    case MapUtils.present_value(request, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, error}
    end
  end

  defp split_parent(parent, opts) do
    case resolve_entry_ref(parent, opts) do
      {:ok, {volume, path}} when is_binary(volume) ->
        {volume, path}

      _ ->
        volumes = list_volumes(opts)

        if Map.has_key?(volumes, parent) do
          {parent, "."}
        else
          SourcePath.split_source(parent, nil, volumes, opts)
        end
    end
  end

  defp parent_source(params) do
    filters = MapUtils.present_value(params, "filters") || %{}

    case MapUtils.present_value(filters, "parent") do
      parent when is_binary(parent) and parent != "" -> parent
      _ -> nil
    end
  end

  defp root_path?(params), do: MapUtils.present_value(params, "path") == "/"

  defp file_explorer(opts), do: Keyword.get(opts, :file_explorer_module, FileExplorer)
  defp entry_catalog(opts), do: Keyword.get(opts, :entry_catalog_module, EntryCatalog)
  defp permissions(opts), do: Keyword.get(opts, :permissions_module, Permissions)
  defp mime(opts), do: Keyword.get(opts, :mime_module, MIME)
end
