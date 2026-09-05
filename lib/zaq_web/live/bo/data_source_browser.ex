defmodule ZaqWeb.Live.BO.DataSourceBrowser do
  @moduledoc """
  Provider-neutral helpers for BO data-source folder browsing.

  LiveViews own their post-success behavior and dispatch functions; this module
  owns source normalization, folder-only navigation state, list parameters, and
  destination parameter construction.
  """

  alias Zaq.Channels.ProviderCatalog

  def source(config, scope) do
    provider = scope |> value(:provider) |> string_or(config.provider)
    scope_id = scope |> value(:scope_id) |> string_or(config.id)
    config_id = value(scope, :config_id) || config.id

    %{
      id: source_id(provider, config_id, scope_id),
      provider: provider,
      config_id: config_id,
      scope_id: scope_id,
      filters: source_filters(scope, scope_id),
      label: value(scope, :label) || fallback_label(config),
      path: value(scope, :path)
    }
  end

  def source_id(provider, config_id, scope_id) do
    Enum.join([provider, to_string(config_id), scope_id], ":")
  end

  def active_source(sources, source_id) when is_list(sources) do
    Enum.find(sources, &(&1.id == source_id)) || List.first(sources)
  end

  def reset_stack, do: []

  def enter_folder(stack, entries, id) when is_list(stack) and is_list(entries) do
    case Enum.find(entries, &(to_string(&1.id) == to_string(id))) do
      nil -> stack
      folder -> stack ++ [folder]
    end
  end

  def up_stack(stack) when is_list(stack), do: Enum.drop(stack, -1)

  def current_folder(source, stack) do
    case List.last(stack || []) do
      nil -> %{id: source && Map.get(source.filters || %{}, "parent"), path: "root"}
      folder -> folder
    end
  end

  def folder(record) do
    %{
      id: record.id,
      name: record.name,
      path: record.path || record.name
    }
  end

  def folders_from_records(records) when is_list(records) do
    records
    |> Enum.filter(&(Map.get(&1, :kind) == :folder))
    |> Enum.map(&folder/1)
  end

  def list_params(source, parent_id, include_permissions \\ false) do
    filters =
      case parent_id do
        nil -> source.filters || %{}
        "" -> source.filters || %{}
        id -> Map.put(source.filters || %{}, "parent", id)
      end

    %{
      "config_id" => source.config_id,
      "filters" => filters,
      "include_permissions" => include_permissions
    }
  end

  def destination_params(source, stack) do
    folder_parent_id = stack |> List.last() |> provider_parent_id()
    folder_parent_path = stack |> List.last() |> provider_parent_path()
    root_parent = Map.get(source.filters || %{}, "parent")
    root_path = Map.get(source.filters || %{}, "path") || root_parent
    parent_id = folder_parent_id || root_parent

    %{
      config_id: source.config_id && to_string(source.config_id),
      parent_id: parent_id,
      path: data_source_parent(root_path, folder_parent_path)
    }
  end

  def create_folder_params(source, stack, name) do
    %{
      name: name,
      kind: "folder",
      provider: source.provider
    }
    |> Map.merge(destination_params(source, stack))
  end

  defp provider_parent_id(%{id: id}) when is_binary(id) and id not in ["", "."], do: id
  defp provider_parent_id(_), do: nil

  defp provider_parent_path(%{path: path}) when is_binary(path) and path not in ["", ".", "root"],
    do: path

  defp provider_parent_path(_), do: nil

  defp data_source_parent(parent, dir) when dir in [nil, "", "."], do: parent

  defp data_source_parent(parent, dir) do
    case parent do
      parent when is_binary(parent) and parent not in ["", "."] -> Path.join(parent, dir)
      _ -> dir
    end
  end

  defp value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp source_filters(scope, scope_id) do
    case value(scope, :filters) do
      filters when is_map(filters) and map_size(filters) > 0 -> filters
      _ -> %{"parent" => scope_id}
    end
  end

  defp string_or(nil, fallback), do: to_string(fallback)
  defp string_or(value, _fallback), do: to_string(value)

  defp fallback_label(%{name: name, provider: provider}) when is_binary(name),
    do: "#{name} · #{provider}"

  defp fallback_label(%{provider: provider}), do: ProviderCatalog.label(provider)
end
