defmodule Zaq.Channels.ProviderCatalogTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.ProviderCatalog

  test "integration_module/1 resolves known provider from catalog discovery" do
    assert {:ok, Jido.Connect.Google.Drive} = ProviderCatalog.integration_module("google_drive")
  end

  test "integration_module/1 returns unsupported when provider is unknown" do
    assert {:error, :unsupported} = ProviderCatalog.integration_module("zaq_local")
  end
end
