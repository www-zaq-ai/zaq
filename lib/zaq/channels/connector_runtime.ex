defmodule Zaq.Channels.ConnectorRuntime do
  @moduledoc "Provider teardown and runtime stages for Engine-resolved connector configurations."

  alias Zaq.Channels.{Bridge, CommunicationBridge}

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

  @doc "Stops the supplied exact connector runtime, without repeating provider ingress teardown."
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
