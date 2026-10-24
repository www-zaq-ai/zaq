defmodule Zaq.Channels.ConnectorRuntime do
  @moduledoc "Provider teardown and runtime stages for Engine-resolved connector configurations."

  alias Zaq.Channels.{Bridge, CommunicationBridge, JidoChatBridge}
  alias Zaq.ConnectorConfig.Settings
  alias Zaq.{Event, NodeRouter}

  @type operation ::
          {:start, module(), keyword()}
          | {:restart, module()}
          | {:ensure, String.t(), keyword()}

  @doc "Routes complete runtime preparation through Channels."
  @spec start(Bridge.runtime_target(), operation()) :: :ok | {:error, term()}
  def start(config, operation) do
    event =
      Event.new(%{config: config, operation: operation}, :channels,
        opts: [action: :connector_start_runtime, confidential: true]
      )

    NodeRouter.dispatch(event).response
  end

  @doc "Rechecks eligibility and prepares the runtime inside the complete routed command."
  def execute_start(%{config: config, operation: operation}) do
    with {:ok, current} <- current_config(config) do
      start_current(current, operation)
    end
  end

  def execute_start(_), do: {:error, :invalid_request}

  defp current_config(%{id: id, provider: _, kind: _, settings: settings} = config)
       when is_integer(id) and id > 0 and is_map(settings) do
    if Settings.saved_binding?(config), do: resolve_current(config), else: {:ok, config}
  end

  defp current_config(config), do: {:ok, config}

  defp resolve_current(%{id: id, provider: provider, kind: kind} = config) do
    event =
      Event.new(%{channel_config_id: id, provider: provider, kind: kind}, :engine,
        opts: [action: :connector_runtime_context, confidential: true, connector_runtime: true]
      )

    case NodeRouter.dispatch(event).response do
      {:ok, current} -> {:ok, Map.merge(config, current)}
      {:error, _} = error -> error
      _ -> {:error, :connector_unavailable}
    end
  end

  defp start_current(config, {:start, bridge, opts}),
    do: Bridge.execute_start(bridge, config, opts)

  defp start_current(config, {:restart, bridge}), do: Bridge.execute_restart(bridge, config)

  defp start_current(config, {:ensure, bridge_id, opts}),
    do: JidoChatBridge.execute_start(config, bridge_id, opts)

  defp start_current(_, _), do: {:error, :invalid_request}

  @doc "Tears down ingress using supplied credentials, without configuration persistence."
  def teardown_ingress(%{kind: "data_source"}, _opts), do: {:ok, :not_required}

  def teardown_ingress(%{id: id, provider: provider} = config, opts) do
    case Bridge.provider_config(provider) do
      %{ingress_mode: :webhook} ->
        module = Keyword.get(opts, :communication_bridge_module, CommunicationBridge)

        case module.delete_ingress_subscription(config, %{strict: true, config_id: id}) do
          {:ok, %{deleted: false, reason: reason}} -> {:ok, {:warning, reason}}
          {:ok, _} -> {:ok, :deleted}
          {:error, :unsupported} -> {:ok, :unsupported}
          {:error, reason} -> {:error, {:ingress_teardown_failed, reason}}
          other -> {:error, {:ingress_teardown_failed, {:unexpected_response, other}}}
        end

      _ ->
        {:ok, :not_required}
    end
  end

  def teardown_ingress(_config, _opts), do: {:error, :invalid_request}

  @doc "Stops the supplied exact connector runtime without repeating provider teardown."
  def sync_runtime(
        %{id: id, provider: provider, kind: kind},
        %{id: id, provider: provider, kind: kind, enabled: false} = after_config,
        opts
      ) do
    with {:ok, bridge} <- runtime_bridge(provider, kind, opts),
         true <-
           (Code.ensure_loaded?(bridge) and function_exported?(bridge, :stop_runtime, 1)) ||
             {:error, :unsupported} do
      bridge.stop_runtime(after_config)
    end
  end

  def sync_runtime(_before, _after, _opts), do: {:error, :connector_mismatch}

  defp runtime_bridge(provider, kind, opts) do
    key =
      if kind == "data_source",
        do: :data_source_runtime_module,
        else: :communication_runtime_module

    case Keyword.get(opts, key) do
      nil -> Bridge.resolve_bridge(provider)
      module -> {:ok, module}
    end
  end
end
