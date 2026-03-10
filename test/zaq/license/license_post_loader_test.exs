defmodule Zaq.License.LicensePostLoaderTest do
  use ExUnit.Case, async: false

  alias Zaq.License.LicensePostLoader

  setup do
    case GenServer.whereis(LicensePostLoader) do
      nil -> start_supervised!(LicensePostLoader)
      _pid -> :ok
    end

    Phoenix.PubSub.subscribe(Zaq.PubSub, "license:updated")
    :ok
  end

  test "notify broadcasts license updated when no migrations are provided" do
    LicensePostLoader.notify(%{"license_key" => "lic_no_migrations"}, [])

    assert_receive :license_updated
  end

  test "notify still broadcasts when migration processing raises" do
    migration_files = [{"nested/path/001_bad.exs", "raise \"boom\""}]

    LicensePostLoader.notify(%{"license_key" => "lic_with_bad_migration"}, migration_files)

    assert_receive :license_updated
  end
end
