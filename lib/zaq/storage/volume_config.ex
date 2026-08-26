defmodule Zaq.Storage.VolumeConfig do
  @moduledoc """
  Validates and normalizes disk data-source volume declarations.

  The persisted source of truth is `Zaq.Channels.ChannelConfig.settings`; Storage owns the
  filesystem-facing interpretation of those settings.
  """

  import Ecto.Changeset

  alias Zaq.Config

  @doc "Returns the configured Storage base path."
  def base_path(opts \\ []) do
    opts
    |> storage_config()
    |> Keyword.get(:base_path)
  end

  @doc "Validates Disk ChannelConfig settings inside a parent changeset."
  def validate_changeset(changeset) do
    case validate_settings(get_field(changeset, :settings) || %{}) do
      :ok -> changeset
      {:error, message} -> add_error(changeset, :settings, message)
    end
  end

  @doc "Converts a Disk ChannelConfig into Storage runtime opts."
  def opts_for_channel_config(config, opts \\ []) do
    settings = settings(config)
    runtime_opts = runtime_config_opts(config, opts)
    base_path = base_path(runtime_opts)

    with :ok <- validate_base_path(base_path),
         {:ok, volumes} <- volumes_from_settings(settings, base_path) do
      {:ok, [storage_config: [base_path: base_path, volumes: volumes]]}
    end
  end

  @doc "Normalizes settings volume declarations without resolving paths."
  def normalize_settings(settings) when is_map(settings) do
    volumes =
      settings
      |> Map.get("volumes", [])
      |> Enum.map(fn volume ->
        %{
          "name" => volume |> map_get("name") |> to_string() |> String.trim(),
          "path" => volume |> map_get("path") |> to_string() |> String.trim()
        }
      end)

    Map.put(settings, "volumes", volumes)
  end

  def normalize_settings(_settings), do: %{"volumes" => []}

  @doc "Validates normalized or raw settings."
  def validate_settings(settings) when is_map(settings) do
    settings = normalize_settings(settings)
    volumes = Map.get(settings, "volumes", [])

    cond do
      volumes == [] ->
        {:error, "at least one volume is required"}

      duplicate_names?(volumes) ->
        {:error, "volume names must be unique"}

      true ->
        validate_volumes(volumes)
    end
  end

  def validate_settings(_settings), do: {:error, "volume settings are invalid"}

  defp volumes_from_settings(settings, base_path) do
    settings = normalize_settings(settings)

    with :ok <- validate_settings(settings) do
      volumes =
        settings
        |> Map.fetch!("volumes")
        |> Map.new(fn %{"name" => name, "path" => path} ->
          {name, Path.join(base_path, path)}
        end)

      {:ok, volumes}
    end
  end

  defp validate_volumes(volumes) do
    Enum.reduce_while(volumes, :ok, fn volume, :ok ->
      case validate_volume(volume) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
  end

  defp validate_base_path(path) when is_binary(path) do
    if String.trim(path) == "", do: {:error, :storage_base_path_required}, else: :ok
  end

  defp validate_base_path(_path), do: {:error, :storage_base_path_required}

  defp validate_volume(%{"name" => name, "path" => path}) do
    cond do
      name == "" -> {:error, "volume name is required"}
      path == "" -> {:error, "volume path is required"}
      Path.type(path) == :absolute -> {:error, "volume path must be relative"}
      path_traversal?(path) -> {:error, "volume path cannot escape the storage base path"}
      true -> :ok
    end
  end

  defp duplicate_names?(volumes) do
    names = Enum.map(volumes, &Map.fetch!(&1, "name"))
    length(names) != length(Enum.uniq(names))
  end

  defp path_traversal?(path) do
    path
    |> Path.split()
    |> Enum.member?("..")
  end

  defp settings(%{settings: settings}) when is_map(settings), do: settings
  defp settings(%{"settings" => settings}) when is_map(settings), do: settings
  defp settings(config) when is_map(config), do: config

  defp map_get(map, "name") when is_map(map), do: Map.get(map, "name") || Map.get(map, :name)
  defp map_get(map, "path") when is_map(map), do: Map.get(map, "path") || Map.get(map, :path)
  defp map_get(_map, _key), do: nil

  defp storage_config(opts) do
    case Keyword.get(opts, :storage_config) do
      nil -> Config.get(:zaq, Zaq.Storage, [], opts)
      config -> config
    end
  end

  defp runtime_config_opts(config, opts) do
    case map_get_storage_config(config) do
      nil -> opts
      storage_config -> Keyword.put(opts, :storage_config, storage_config)
    end
  end

  defp map_get_storage_config(%{storage_config: storage_config}), do: storage_config
  defp map_get_storage_config(%{"storage_config" => storage_config}), do: storage_config
  defp map_get_storage_config(_config), do: nil
end
