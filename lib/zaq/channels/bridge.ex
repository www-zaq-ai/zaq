defmodule Zaq.Channels.Bridge do
  @moduledoc """
  Behaviour and shared helpers for channel bridge modules.

  Responsibilities:

  - Define required bridge contract callbacks (`to_internal/2`, `send_reply/2`).
  - Provide optional runtime/lifecycle callback contracts used by bridge-specific
    runtimes.
  - Provide shared provider resolution and connection/config lookup helpers.
  - Provide shared incoming routing hooks and persistence helper
    (`persist_from_incoming/5`) that routes through `NodeRouter.dispatch/1` when
    using the default engine conversations module.

  This module does not implement provider transport logic directly; concrete
  bridge modules own transport-specific behavior.
  """

  alias Zaq.Channels.{ChannelConfig, CommunicationBridge, DataSourceBridge}
  alias Zaq.Engine.Conversations
  alias Zaq.Engine.Messages.Incoming
  alias Zaq.{Event, NodeRouter}

  @smtp_provider "email:smtp"
  @imap_provider "email:imap"

  @callback to_internal(map(), map()) :: Incoming.t() | {:error, term()}
  @callback capability_snapshot(map()) :: {:ok, map()} | {:error, term()}

  @callback start_runtime(map()) :: :ok | {:error, term()}
  @callback stop_runtime(map()) :: :ok | {:error, term()}
  @callback sync_runtime(map() | nil, map()) :: :ok | {:error, term()}
  @callback sync_provider_runtime(map()) :: :ok | {:error, term()}
  @callback build_runtime_specs(map()) :: {:ok, {map() | nil, list()}} | {:error, term()}
  @callback runtime_update_enabled_enabled(map(), map()) :: :ok | {:error, term()}
  @callback runtime_supervisor_module() :: module()
  @callback runtime_bridge_id(map()) :: String.t()
  @callback test_connection(map(), String.t()) :: {:ok, term()} | {:error, term()}
  @callback before_incoming(map(), map(), keyword(), module()) ::
              {:ok, {map(), map(), keyword()}} | {:error, term()}
  @callback after_incoming(map(), map(), keyword(), term(), module()) :: term()

  @optional_callbacks start_runtime: 1,
                      stop_runtime: 1,
                      sync_runtime: 2,
                      sync_provider_runtime: 1,
                      runtime_update_enabled_enabled: 2,
                      build_runtime_specs: 1,
                      runtime_supervisor_module: 0,
                      runtime_bridge_id: 1,
                      before_incoming: 4,
                      after_incoming: 5,
                      test_connection: 2,
                      capability_snapshot: 1

  @communication_required_capabilities [
    :text,
    :image,
    :audio,
    :video,
    :file,
    :streaming,
    :reactions,
    :threads,
    :typing,
    :mode
  ]

  @communication_capability_meta %{
    text: "Text",
    image: "Image",
    audio: "Audio",
    video: "Video",
    file: "File",
    streaming: "Streaming",
    reactions: "Reactions",
    threads: "Threads",
    typing: "Typing",
    mode: "Mode"
  }

  defmacro __using__(_opts) do
    quote do
      alias Zaq.Channels.Bridge, as: ChannelBridge

      defdelegate route_incoming(bridge_module, config, payload, sink_opts),
        to: Zaq.Channels.Bridge

      defdelegate bridge_for(provider), to: Zaq.Channels.Bridge
      defdelegate provider_to_bridge_key(provider), to: Zaq.Channels.Bridge
      defdelegate resolve_bridge(provider), to: Zaq.Channels.Bridge
      defdelegate fetch_connection_details(provider), to: Zaq.Channels.Bridge
      defdelegate fetch_channel_config(provider), to: Zaq.Channels.Bridge
      defdelegate fetch_any_channel_config(provider), to: Zaq.Channels.Bridge

      defdelegate dispatch_provider_runtime_sync(bridge, config),
        to: Zaq.Channels.Bridge

      def start_runtime(config) do
        bridge_id = runtime_bridge_id(config)

        with true <-
               function_exported?(__MODULE__, :build_runtime_specs, 1) || {:error, :unsupported},
             {:ok, {state_spec, listeners}} <- build_runtime_specs(config) do
          case runtime_supervisor_module().start_runtime(bridge_id, state_spec, listeners) do
            {:ok, _runtime} -> :ok
            {:error, :already_running} -> ChannelBridge.restart_runtime(__MODULE__, config)
            {:error, reason} -> {:error, reason}
          end
        end
      end

      def stop_runtime(config),
        do: ChannelBridge.stop_runtime_normalized(__MODULE__, config)

      def sync_runtime(nil, %{enabled: true} = config), do: start_runtime(config)
      def sync_runtime(nil, %{enabled: false}), do: :ok
      def sync_runtime(%{enabled: true}, %{enabled: false} = config), do: stop_runtime(config)
      def sync_runtime(%{enabled: false}, %{enabled: true} = config), do: start_runtime(config)

      def sync_runtime(%{enabled: true} = before_config, %{enabled: true} = after_config),
        do: runtime_update_enabled_enabled(before_config, after_config)

      def sync_runtime(_before, _after), do: :ok

      def sync_provider_runtime(%{enabled: false} = config), do: stop_runtime(config)
      def sync_provider_runtime(%{enabled: true} = config), do: start_runtime(config)

      def runtime_update_enabled_enabled(_before, _after), do: :ok

      def runtime_supervisor_module, do: Zaq.Channels.Supervisor

      def runtime_bridge_id(config), do: ChannelBridge.default_bridge_id(config)

      defoverridable start_runtime: 1,
                     stop_runtime: 1,
                     sync_runtime: 2,
                     sync_provider_runtime: 1,
                     runtime_update_enabled_enabled: 2,
                     runtime_supervisor_module: 0,
                     runtime_bridge_id: 1
    end
  end

  @spec default_bridge_id(map()) :: String.t()
  def default_bridge_id(config),
    do:
      "#{Map.get(config, :provider) || Map.get(config, "provider")}_#{Map.get(config, :id) || Map.get(config, "id")}"

  @spec stop_runtime_normalized(module(), map()) :: :ok | {:error, term()}
  def stop_runtime_normalized(bridge_module, config)
      when is_atom(bridge_module) and is_map(config) do
    case bridge_module.runtime_supervisor_module().stop_bridge_runtime(
           config,
           bridge_module.runtime_bridge_id(config)
         ) do
      :ok -> :ok
      {:error, :not_running} -> :ok
      other -> other
    end
  end

  @spec restart_runtime(module(), map()) :: :ok | {:error, term()}
  def restart_runtime(bridge_module, config) when is_atom(bridge_module) and is_map(config) do
    with true <-
           function_exported?(bridge_module, :build_runtime_specs, 1) || {:error, :unsupported},
         :ok <- stop_runtime_normalized(bridge_module, config),
         {:ok, {state_spec, listeners}} <- bridge_module.build_runtime_specs(config) do
      case bridge_module.runtime_supervisor_module().start_runtime(
             bridge_module.runtime_bridge_id(config),
             state_spec,
             listeners
           ) do
        {:ok, _runtime} -> :ok
        {:error, :already_running} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Routes inbound payloads through optional hooks and bridge handler."
  @spec route_incoming(module(), map(), map(), keyword()) :: term()
  def route_incoming(bridge_module, config, payload, sink_opts)
      when is_atom(bridge_module) and is_map(config) and is_map(payload) and is_list(sink_opts) do
    with {:ok, {hook_config, hook_payload, hook_sink_opts}} <-
           before_incoming(config, payload, sink_opts, bridge_module),
         true <-
           function_exported?(bridge_module, :handle_from_listener, 3) || {:error, :unsupported},
         result <- bridge_module.handle_from_listener(hook_config, hook_payload, hook_sink_opts) do
      after_incoming(hook_config, hook_payload, hook_sink_opts, result, bridge_module)
    else
      {:error, _reason} = error -> error
      false -> {:error, :unsupported}
      other -> other
    end
  end

  @doc "Default before-incoming hook pass-through."
  @spec before_incoming(map(), map(), keyword(), module()) ::
          {:ok, {map(), map(), keyword()}} | {:error, term()}
  def before_incoming(config, payload, sink_opts, bridge_module)
      when is_map(config) and is_map(payload) and is_list(sink_opts) and is_atom(bridge_module) do
    if function_exported?(bridge_module, :before_incoming, 4) do
      bridge_module.before_incoming(config, payload, sink_opts, __MODULE__)
    else
      {:ok, {config, payload, sink_opts}}
    end
  end

  @doc "Default after-incoming hook pass-through."
  @spec after_incoming(map(), map(), keyword(), term(), module()) :: term()
  def after_incoming(config, payload, sink_opts, result, bridge_module)
      when is_map(config) and is_map(payload) and is_list(sink_opts) and is_atom(bridge_module) do
    if function_exported?(bridge_module, :after_incoming, 5) do
      bridge_module.after_incoming(config, payload, sink_opts, result, __MODULE__)
    else
      result
    end
  end

  @doc "Normalizes event/bridge ack responses to `:ok` or `{:error, reason}`."
  @spec ack_from_event_response(term()) :: :ok | {:error, term()}
  def ack_from_event_response(response)

  def ack_from_event_response(:ok), do: :ok
  def ack_from_event_response({:ok, _ack}), do: :ok
  def ack_from_event_response({:error, _reason} = error), do: error
  def ack_from_event_response(%{ack: ack}), do: ack_from_event_response(ack)
  def ack_from_event_response(%{"ack" => ack}), do: ack_from_event_response(ack)
  def ack_from_event_response(%Event{response: response}), do: ack_from_event_response(response)
  def ack_from_event_response(other), do: {:error, {:invalid_ack, other}}

  @doc """
  Persists a processed incoming message and its metadata through the engine.

  If `conversations_module` is the default `Zaq.Engine.Conversations`, routing
  goes through `NodeRouter.dispatch/1` and the event envelope. Otherwise the
  override module is called directly for testability.
  """
  @spec persist_from_incoming(Incoming.t(), map(), module(), term(), module()) :: term()
  def persist_from_incoming(
        %Incoming{} = incoming,
        metadata,
        conversations_module,
        actor,
        node_router_module \\ NodeRouter
      )
      when is_map(metadata) and is_atom(conversations_module) and is_atom(node_router_module) do
    if conversations_module == Conversations do
      event =
        Event.new(
          %{incoming: incoming, metadata: metadata},
          :engine,
          actor: actor,
          opts: [action: :persist_from_incoming]
        )

      node_router_module.dispatch(event).response
    else
      conversations_module.persist_from_incoming(incoming, metadata)
    end
  end

  @doc "Returns the configured bridge module for provider."
  @spec bridge_for(atom() | String.t()) :: module() | nil
  def bridge_for(provider) when is_binary(provider) do
    provider
    |> provider_to_bridge_key()
    |> case do
      nil -> nil
      key -> bridge_for(key)
    end
  end

  def bridge_for(provider) when is_atom(provider) do
    :zaq
    |> Application.get_env(:channels, %{})
    |> get_in([provider, :bridge])
  end

  @doc "Maps provider string keys to configured bridge keys."
  @spec provider_to_bridge_key(String.t()) :: atom() | nil
  def provider_to_bridge_key(@smtp_provider), do: :email
  def provider_to_bridge_key(@imap_provider), do: :email

  def provider_to_bridge_key(provider) do
    String.to_existing_atom(provider)
  rescue
    ArgumentError -> nil
  end

  @doc "Resolves configured bridge for provider."
  @spec resolve_bridge(atom() | String.t()) :: {:ok, module()} | {:error, term()}
  def resolve_bridge(provider) do
    case bridge_for(provider) do
      nil -> {:error, {:no_bridge, provider}}
      bridge -> {:ok, bridge}
    end
  end

  @doc "Fetches connection details by provider."
  @spec fetch_connection_details(atom() | String.t()) :: map()
  def fetch_connection_details(:web), do: %{}

  def fetch_connection_details(provider) do
    case ChannelConfig.get_by_provider(to_string(provider)) do
      nil -> %{}
      config -> %{url: config.url, token: config.token}
    end
  end

  @doc "Fetches enabled channel config by provider."
  @spec fetch_channel_config(atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_channel_config(provider) do
    case ChannelConfig.get_by_provider(to_string(provider)) do
      nil -> {:error, {:channel_not_configured, provider}}
      config -> {:ok, config}
    end
  end

  @doc "Fetches channel config by provider, including disabled entries."
  @spec fetch_any_channel_config(atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def fetch_any_channel_config(provider) do
    case ChannelConfig.get_any_by_provider(to_string(provider)) do
      nil -> {:error, {:channel_not_configured, provider}}
      config -> {:ok, config}
    end
  end

  @doc "Delegates provider runtime sync to bridge callback or fallback runtime hooks."
  @spec dispatch_provider_runtime_sync(module(), map()) :: :ok | {:error, term()}
  def dispatch_provider_runtime_sync(bridge, config) do
    if bridge_supports?(bridge, :sync_provider_runtime, 1) do
      bridge.sync_provider_runtime(config)
    else
      fallback_sync_provider_runtime(config)
    end
  end

  @doc "Returns standardized capability snapshot for a provider."
  @spec capability_snapshot(atom() | String.t()) :: {:ok, map()} | {:error, term()}
  def capability_snapshot(provider) do
    with {:ok, bridge} <- resolve_bridge(provider),
         {:ok, config} <- fetch_channel_config(provider),
         true <- bridge_supports?(bridge, :capability_snapshot, 1) || {:error, :unsupported},
         {:ok, raw_snapshot} <- bridge.capability_snapshot(config) do
      {:ok, normalize_capability_snapshot(raw_snapshot, config)}
    end
  end

  @doc "Synchronizes runtime processes when a channel config changes via centralized Bridge resolution."
  @spec sync_config_runtime(map() | nil, map()) :: :ok | {:error, term()}
  def sync_config_runtime(before_config, after_config),
    do: CommunicationBridge.sync_config_runtime(before_config, after_config)

  @doc "Synchronizes runtime processes from canonical DB config for provider."
  @spec sync_provider_runtime(atom() | String.t()) :: :ok | {:error, term()}
  def sync_provider_runtime(provider),
    do: CommunicationBridge.sync_provider_runtime(provider)

  @doc "Returns required capabilities for a channel kind."
  @spec required_capabilities(:communication | :data_source) :: [atom()]
  def required_capabilities(:communication), do: @communication_required_capabilities
  def required_capabilities(:data_source), do: DataSourceBridge.required_capabilities()

  @doc "Returns capability labels for a channel kind."
  @spec capability_meta(:communication | :data_source) :: map()
  def capability_meta(:communication), do: @communication_capability_meta
  def capability_meta(:data_source), do: DataSourceBridge.capability_meta()

  defp fallback_sync_provider_runtime(config) do
    if config.enabled do
      with_bridge_runtime(config, :start_runtime)
    else
      with_bridge_runtime(config, :stop_runtime)
    end
  end

  defp with_bridge_runtime(%{provider: provider} = config, fun)
       when fun in [:start_runtime, :stop_runtime] do
    with {:ok, bridge} <- resolve_bridge(provider),
         true <- bridge_supports?(bridge, fun, 1) || :unsupported do
      apply(bridge, fun, [config])
    else
      :unsupported -> :ok
    end
  end

  defp bridge_supports?(bridge, fun, arity)
       when is_atom(bridge) and is_atom(fun) and is_integer(arity) do
    Code.ensure_loaded?(bridge) and function_exported?(bridge, fun, arity)
  end

  defp normalize_capability_snapshot(raw_snapshot, config) do
    kind = capability_kind(config)
    required = map_get_list(raw_snapshot, [:required, "required"]) || required_capabilities(kind)
    resolved = map_get_map(raw_snapshot, [:resolved, "resolved"]) || %{}

    labels =
      capability_meta(kind)
      |> Map.merge(map_get_map(raw_snapshot, [:labels, "labels"]) || %{})

    unsupported =
      map_get_list(raw_snapshot, [:unsupported, "unsupported"]) ||
        Enum.reject(required, &capability_resolved?(resolved, &1))

    %{
      kind: kind,
      required: required,
      resolved: resolved,
      unsupported: unsupported,
      labels: labels
    }
  end

  defp capability_kind(%{kind: "data_source"}), do: :data_source
  defp capability_kind(%{"kind" => "data_source"}), do: :data_source
  defp capability_kind(_), do: :communication

  defp capability_resolved?(resolved, key) do
    value = Map.get(resolved, key) || Map.get(resolved, to_string(key))
    not is_nil(value) and value != false
  end

  defp map_get_list(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        list when is_list(list) -> list
        _ -> nil
      end
    end)
  end

  defp map_get_list(_, _), do: nil

  defp map_get_map(map, keys) when is_map(map) and is_list(keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_map(value) -> value
        _ -> nil
      end
    end)
  end

  defp map_get_map(_, _), do: nil
end
