defmodule Zaq.Engine.ChannelAdapterLoader do
  @moduledoc """
  Shared helper for building supervised channel adapter children.

  Used by `IngestionSupervisor` and `RetrievalSupervisor` to centralise
  the common boot sequence:

  - load enabled channel configs for a kind,
  - map config providers to adapter modules,
  - build Supervisor child spec entries with the correct start function.

  Expected adapter contract:

  - retrieval adapters expose `connect/1`
  - ingestion adapters expose `start_link/1`

  ## Example

      children =
        Zaq.Engine.ChannelAdapterLoader.children_for(:retrieval, @adapters,
          start_fun: :connect,
          supervisor_name: "RetrievalSupervisor",
          kind_label: "retrieval"
        )

  Required options:

  - `:start_fun` (`:connect` or `:start_link`)
  - `:supervisor_name` (used in logs)

  Optional options:

  - `:kind_label` (defaults to `to_string(kind)`)
  """

  alias Zaq.Channels.ChannelConfig

  require Logger

  @type child_start :: :connect | :start_link

  @doc "Builds child specs for enabled configs of the given kind."
  @spec children_for(atom(), map(), keyword()) :: [Supervisor.child_spec()]
  def children_for(kind, adapters, opts) when is_map(adapters) and is_list(opts) do
    start_fun = Keyword.fetch!(opts, :start_fun)
    supervisor_name = Keyword.fetch!(opts, :supervisor_name)
    kind_label = Keyword.get(opts, :kind_label, to_string(kind))
    providers = Map.keys(adapters)

    kind
    |> load_configs(providers, supervisor_name, kind_label)
    |> Enum.flat_map(&build_child_spec(&1, adapters, start_fun, supervisor_name, kind_label))
  end

  @doc "Loads enabled channel configs for a kind and known providers, logging when none are configured."
  @spec load_configs(atom(), [String.t()], String.t(), String.t()) :: [map()]
  def load_configs(kind, providers, supervisor_name, kind_label) do
    case ChannelConfig.list_enabled_by_kind(kind, providers) do
      [] ->
        Logger.info(
          "[#{supervisor_name}] No enabled #{kind_label} channel configs found, starting empty."
        )

        []

      configs ->
        configs
    end
  end

  @doc "Builds a child spec for a config or returns an empty list for unknown providers."
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
