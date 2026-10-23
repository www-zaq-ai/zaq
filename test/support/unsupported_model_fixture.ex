defmodule Zaq.UnsupportedModelFixture do
  @moduledoc false

  alias Zaq.Agent.ProviderModels.Adapter

  # Install only in synchronous tests: LiveViews resolve this adapter in another process.
  def install do
    previous = Application.fetch_env(:zaq, :provider_models_adapter)

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        {:ok, adapter} -> Application.put_env(:zaq, :provider_models_adapter, adapter)
        :error -> Application.delete_env(:zaq, :provider_models_adapter)
      end
    end)

    Application.put_env(:zaq, :provider_models_adapter, __MODULE__)
  end

  def models(:novita_ai) do
    [
      %LLMDB.Model{
        id: "qwen/qwen3-4b-fp8",
        provider: :novita_ai,
        name: "Fixture model without tools",
        capabilities: %{tools: %{enabled: false}},
        deprecated: false,
        retired: false
      }
    ]
  end

  def models(provider), do: Adapter.models(provider)
  defdelegate provider(provider), to: Adapter
  defdelegate parse_provider(provider), to: Adapter
  defdelegate available_models(opts), to: Adapter
  defdelegate model(spec), to: Adapter
end
