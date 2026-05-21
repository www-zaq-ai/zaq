defmodule Zaq.Channels.ProviderCatalogTest do
  use ExUnit.Case, async: false

  alias Zaq.Channels.ProviderCatalog

  test "label/1 returns known provider labels and fallback label" do
    assert "Google Drive" == ProviderCatalog.label("google_drive")
    assert "Custom provider" == ProviderCatalog.label("custom_provider")
  end

  test "root_folder_default/1 returns provider defaults and fallback" do
    assert "root" == ProviderCatalog.root_folder_default("google_drive")
    assert "/" == ProviderCatalog.root_folder_default("zaq_local")
    assert "root" == ProviderCatalog.root_folder_default("custom_provider")
  end

  test "credential helpers return expected provider and format" do
    assert "local_filesystem" == ProviderCatalog.credential_provider("zaq_local")
    assert "google_drive" == ProviderCatalog.credential_provider("google_drive")
    assert "bearer" == ProviderCatalog.credential_request_format("google_drive")
  end

  test "oauth_module/1 resolves supported provider and rejects unknown" do
    assert {:ok, Jido.Connect.Google.OAuth} = ProviderCatalog.oauth_module("google_drive")
    assert {:error, :unsupported} = ProviderCatalog.oauth_module("sharepoint")
  end
end
