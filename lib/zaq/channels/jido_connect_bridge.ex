defmodule Zaq.Channels.JidoConnectBridge do
  @moduledoc """
  DataSource bridge for jido_connect-backed providers.

  Credentials and grants are resolved exclusively through `Zaq.Engine.Connect`
  and mapped to runtime contracts by `Zaq.Engine.Connect.RuntimeMapper`.
  """

  @behaviour Zaq.Channels.Bridge
  @behaviour Zaq.Channels.DataSourceBridge
  use Zaq.Channels.Bridge

  alias Zaq.Channels.Bridge
  alias Zaq.Engine.Connect
  alias Zaq.Engine.Connect.RuntimeMapper

  @impl true
  def auth_handshake(config, params) when is_map(config) and is_map(params),
    do: call_adapter(config, :auth_handshake, [runtime_ctx(config), params])

  @impl true
  def list_resources(config, params) when is_map(config) and is_map(params),
    do: call_adapter(config, :list_resources, [runtime_ctx(config), params])

  @impl true
  def download_resource(config, resource, params)
      when is_map(config) and is_map(resource) and is_map(params),
      do: call_adapter(config, :download_resource, [runtime_ctx(config), resource, params])

  @impl true
  def setup_listener(config, params) when is_map(config) and is_map(params),
    do: call_adapter(config, :setup_listener, [runtime_ctx(config), params])

  @impl true
  def teardown_listener(config, params) when is_map(config) and is_map(params),
    do: call_adapter(config, :teardown_listener, [runtime_ctx(config), params])

  @impl true
  def build_runtime_specs(_config), do: {:ok, {nil, []}}

  @impl true
  def to_internal(_payload, _config), do: {:error, :unsupported}

  defp runtime_ctx(%{provider: provider, id: id}) do
    grant =
      Connect.get_active_grant(%{
        provider: provider,
        resource_type: "data_source",
        resource_id: id,
        owner_type: "org",
        owner_id: nil
      })

    with %{credential_id: credential_id} = grant <- grant,
         {:ok, credential} <- Connect.fetch_credential(credential_id) do
      {:ok,
       %{
         connection: RuntimeMapper.to_connection(grant),
         lease: RuntimeMapper.to_credential_lease(grant, credential),
         grant: grant,
         credential: credential
       }}
    else
      nil -> {:error, :missing_active_grant}
      {:error, :not_found} -> {:error, :credential_not_found}
    end
  end

  defp call_adapter(config, fun, args) when is_map(config) and is_atom(fun) and is_list(args) do
    with {:ok, %{adapter: adapter}} <- provider_cfg(config.provider),
         true <- function_exported?(adapter, fun, length(args)) || {:error, :unsupported},
         {:ok, runtime} <- List.first(args) do
      apply(adapter, fun, [runtime | Enum.drop(args, 1)])
    else
      {:error, _} = error -> error
      false -> {:error, :unsupported}
    end
  end

  defp provider_cfg(provider) do
    key = Bridge.provider_to_bridge_key(to_string(provider))

    case get_in(Application.get_env(:zaq, :channels, %{}), [key]) do
      %{adapter: _} = cfg -> {:ok, cfg}
      _ -> {:error, {:provider_not_configured, provider}}
    end
  end
end
