defmodule Zaq.Channels.ProviderCatalogTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.ProviderCatalog

  defmodule IntegrationStub do
  end

  setup do
    original_channels = Application.get_env(:zaq, :channels)

    on_exit(fn ->
      if is_nil(original_channels) do
        Application.delete_env(:zaq, :channels)
      else
        Application.put_env(:zaq, :channels, original_channels)
      end
    end)

    :ok
  end

  test "integration_module/1 returns configured integration module" do
    Application.put_env(:zaq, :channels, %{
      email: %{integration: IntegrationStub}
    })

    assert {:ok, IntegrationStub} = ProviderCatalog.integration_module("email:imap")
  end

  test "integration_module/1 returns provider_not_configured when integration is missing" do
    Application.put_env(:zaq, :channels, %{})

    assert {:error, {:provider_not_configured, "zaq_local"}} =
             ProviderCatalog.integration_module("zaq_local")
  end
end
