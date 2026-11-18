defmodule Zaq.UserPortal.InstallationWorker do
  @moduledoc "Applies Portal-supplied instance settings without contacting the Portal."

  use Oban.Worker, queue: :default, max_attempts: 5

  alias Zaq.Contracts.Record
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Event
  alias Zaq.NodeRouter
  alias Zaq.Storage.VolumeConfig

  @actor %{kind: :system, subject: "portal-installation"}
  @volume "Documents"

  @doc false
  def valid_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, query: nil, fragment: nil}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  def valid_url?(_), do: false

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"installation_url" => url, "deploy_on_own_cluster" => own?}})
      when is_boolean(own?) do
    with true <- valid_url?(url),
         :ok <-
           required(:global_url, fn ->
             dispatch_engine(:system_config_set_global_base_url, %{base_url: url})
           end) do
      configure_cluster(own?)
    else
      false -> {:cancel, :invalid_installation}
      {:error, _} = error -> error
    end
  end

  def perform(_job), do: {:cancel, :invalid_installation}

  defp configure_cluster(false), do: :ok

  defp configure_cluster(true) do
    with {:ok, config} <- required(:disk, &enable_disk/0),
         {:ok, screenshots} <-
           required(:screenshot_folder, fn -> folder(config, ".web_browser") end),
         {:ok, skills} <- required(:skills_folder, fn -> folder(config, ".SKILLS") end),
         {:ok, _} <-
           required(:screenshot_destination, fn ->
             dispatch_engine(:system_config_save_web_browsing_config, %{attrs: screenshots})
           end),
         {:ok, _} <- required(:skills_destination, fn -> save_skills(skills) end) do
      :ok
    end
  end

  defp save_skills(destination) do
    case dispatch_engine(:system_config_save_skill_resource_config, %{attrs: destination}) do
      {:ok, ^destination} = saved -> saved
      _ -> {:error, :skills_destination_not_saved}
    end
  end

  defp dispatch_engine(action, request) do
    request
    |> Event.new(:engine, actor: @actor, opts: [action: action])
    |> NodeRouter.dispatch()
    |> Map.fetch!(:response)
  end

  defp enable_disk do
    with path when is_binary(path) and path != "" <- VolumeConfig.base_path() do
      previous = ChannelConfig.get_any_by_provider("disk")

      settings = previous |> settings() |> VolumeConfig.normalize_settings()
      other_volumes = Enum.reject(settings["volumes"], &(&1["name"] == @volume))

      settings =
        Map.merge(settings, %{
          "volumes" => [%{"name" => @volume, "path" => "."} | other_volumes],
          "default_volume" => @volume
        })

      ChannelConfig.upsert_by_provider("disk", %{
        name: if(previous, do: previous.name, else: "Disk"),
        kind: "data_source",
        enabled: true,
        settings: settings
      })
    end
  end

  defp settings(nil), do: %{}
  defp settings(config), do: config.settings || %{}

  defp folder(config, name) do
    request = %{
      provider: "disk",
      params: %{"config_id" => config.id, "path" => @volume, "name" => name, "kind" => "folder"}
    }

    result =
      request
      |> Event.new(:channels,
        actor: @actor,
        opts: [action: :data_source_create_file, skip_permissions: true]
      )
      |> NodeRouter.dispatch()
      |> Map.get(:response)

    case result do
      {:ok, %{record: %Record{kind: :folder, id: id, path: path}}} ->
        {:ok,
         %{
           provider: "disk",
           config_id: config.id,
           scope_id: @volume,
           folder_id: id,
           folder_path: path
         }}

      error ->
        error
    end
  end

  defp required(step, operation) do
    case operation.() do
      :ok -> :ok
      {:ok, _} = ok -> ok
      _ -> {:error, step}
    end
  end
end
