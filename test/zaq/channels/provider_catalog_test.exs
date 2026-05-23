defmodule Zaq.Channels.ProviderCatalogTest do
  use ExUnit.Case, async: true

  alias Zaq.Channels.ProviderCatalog

  test "routes google_drive file and sheet capabilities to expected connector providers" do
    assert ProviderCatalog.connector_provider_for_capability("google_drive", :update_item) ==
             :google_drive

    assert ProviderCatalog.connector_provider_for_capability("google_drive", :sheet_update_values) ==
             :google_sheets

    assert ProviderCatalog.connector_provider_for_capability("google_drive", :sheet_inspect) ==
             :google_sheets

    assert ProviderCatalog.connector_provider_for_capability("google_drive", :sheet_add_tab) ==
             :google_sheets
  end

  test "returns capability suffixes for file and sheet operations" do
    assert "file.update" in ProviderCatalog.capability_action_suffixes(:update_item)
    assert "values.update" in ProviderCatalog.capability_action_suffixes(:sheet_update_values)
    assert ProviderCatalog.capability_action_suffixes(:sheet_get) == ["values.get"]
    assert ProviderCatalog.capability_action_suffixes(:sheet_inspect) == ["spreadsheet.get"]
    assert ProviderCatalog.capability_action_suffixes(:sheet_add_tab) == ["sheet.add"]
  end
end
