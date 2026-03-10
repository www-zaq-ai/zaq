defmodule Zaq.License.FeatureStoreTest do
  use ExUnit.Case, async: false

  alias Zaq.License.FeatureStore

  setup do
    case GenServer.whereis(FeatureStore) do
      nil -> start_supervised!(FeatureStore)
      _pid -> :ok
    end

    FeatureStore.clear()
    on_exit(fn -> FeatureStore.clear() end)
    :ok
  end

  test "returns empty defaults before storing" do
    assert FeatureStore.license_data() == nil
    assert FeatureStore.loaded_modules() == []
    refute FeatureStore.feature_loaded?("ontology")
    refute FeatureStore.module_loaded?(Elixir.Does.Not.Exist)
  end

  test "stores and serves license data and module list" do
    license_data = %{
      "license_key" => "lic_store_1",
      "features" => [%{"name" => "ontology"}, %{"name" => "analytics"}]
    }

    loaded_modules = [LicenseManager.Paid.Ontology, LicenseManager.Paid.Analytics]

    assert :ok = FeatureStore.store(license_data, loaded_modules)

    assert FeatureStore.license_data() == license_data
    assert FeatureStore.loaded_modules() == loaded_modules
    assert FeatureStore.feature_loaded?("ontology")
    refute FeatureStore.feature_loaded?("missing")
    assert FeatureStore.module_loaded?(LicenseManager.Paid.Analytics)
    refute FeatureStore.module_loaded?(LicenseManager.Paid.Missing)
  end

  test "clear removes all stored entries" do
    assert :ok = FeatureStore.store(%{"features" => [%{"name" => "x"}]}, [LicenseManager.Paid.X])
    assert :ok = FeatureStore.clear()

    assert FeatureStore.license_data() == nil
    assert FeatureStore.loaded_modules() == []
    refute FeatureStore.feature_loaded?("x")
  end
end
