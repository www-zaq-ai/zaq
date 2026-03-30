defmodule Zaq.Engine.AdapterSupervisor do
  @moduledoc false

  alias Zaq.Channels.ChannelConfig

  require Logger

  @type child_start :: :connect | :start_link

  @spec children_for(atom(), map(), keyword()) :: [Supervisor.child_spec()]
  def children_for(kind, adapters, opts) when is_map(adapters) and is_list(opts) do
    start_fun = Keyword.fetch!(opts, :start_fun)
    supervisor_name = Keyword.fetch!(opts, :supervisor_name)
    kind_label = Keyword.get(opts, :kind_label, to_string(kind))

    kind
    |> load_configs(supervisor_name, kind_label)
    |> Enum.flat_map(&build_child_spec(&1, adapters, start_fun, supervisor_name, kind_label))
  end

  @spec load_configs(atom(), String.t(), String.t()) :: [map()]
  def load_configs(kind, supervisor_name, kind_label) do
    case ChannelConfig.list_enabled_by_kind(kind) do
      [] ->
        Logger.info(
          "[#{supervisor_name}] No enabled #{kind_label} channel configs found, starting empty."
        )

        []

      configs ->
        configs
    end
  end

  @spec build_child_spec(map(), map(), child_start(), String.t(), String.t()) ::
          [Supervisor.child_spec()]
  def build_child_spec(config, adapters, start_fun, supervisor_name, kind_label) do
    case Map.get(adapters, config.provider) do
      nil ->
        Logger.warning(
          "[#{supervisor_name}] Unknown #{kind_label} provider #{inspect(config.provider)}, skipping."
        )

        []

      adapter_module ->
        [
          %{
            id: {adapter_module, config.id},
            start: {adapter_module, start_fun, [config]},
            restart: :permanent
          }
        ]
    end
  end
end
