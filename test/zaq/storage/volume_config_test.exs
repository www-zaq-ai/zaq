defmodule Zaq.Storage.VolumeConfigTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Zaq.Storage.VolumeConfig

  setup do
    original = Application.get_env(:zaq, Zaq.Storage)
    Application.put_env(:zaq, Zaq.Storage, base_path: "priv/documents")

    on_exit(fn ->
      if original,
        do: Application.put_env(:zaq, Zaq.Storage, original),
        else: Application.delete_env(:zaq, Zaq.Storage)
    end)
  end

  test "normalizes volume declarations from string or atom keys" do
    settings = %{"volumes" => [%{"name" => "Archive", :path => "archive"}]}

    assert VolumeConfig.normalize_settings(settings) == %{
             "volumes" => [%{"name" => "Archive", "path" => "archive"}],
             "default_volume" => "Archive"
           }
  end

  property "normalizes every non-map term to empty volume settings" do
    non_map = StreamData.term() |> StreamData.filter(&(not is_map(&1)))

    check all(settings <- non_map) do
      assert VolumeConfig.normalize_settings(settings) == %{
               "volumes" => [],
               "default_volume" => nil
             }

      assert VolumeConfig.validate_settings(settings) == {:error, "volume settings are invalid"}
    end
  end

  test "normalizes nil volume declarations to blank fields and requires a name" do
    assert VolumeConfig.normalize_settings(%{"volumes" => [nil]}) == %{
             "volumes" => [%{"name" => "", "path" => ""}],
             "default_volume" => ""
           }

    assert VolumeConfig.validate_settings(%{"volumes" => [nil]}) ==
             {:error, "volume name is required"}
  end

  test "keeps a valid default volume and promotes the first volume when missing or stale" do
    settings = %{
      "default_volume" => "second",
      "volumes" => [
        %{"name" => "first", "path" => "first"},
        %{"name" => "second", "path" => "second"}
      ]
    }

    assert %{"default_volume" => "second"} = VolumeConfig.normalize_settings(settings)

    assert %{"default_volume" => "first"} =
             VolumeConfig.normalize_settings(%{settings | "default_volume" => "missing"})

    assert %{"default_volume" => "first"} =
             VolumeConfig.normalize_settings(Map.delete(settings, "default_volume"))
  end

  test "rejects missing, duplicate, absolute, and traversal volume paths" do
    assert {:error, "at least one volume is required"} = VolumeConfig.validate_settings(%{})

    assert {:error, "volume names must be unique"} =
             VolumeConfig.validate_settings(%{
               "volumes" => [
                 %{"name" => "docs", "path" => "docs"},
                 %{"name" => "docs", "path" => "other"}
               ]
             })

    assert {:error, "volume path must be relative"} =
             VolumeConfig.validate_settings(%{
               "volumes" => [%{"name" => "docs", "path" => "/tmp"}]
             })

    assert {:error, "volume path cannot escape the storage base path"} =
             VolumeConfig.validate_settings(%{
               "volumes" => [%{"name" => "docs", "path" => "../tmp"}]
             })
  end

  test "builds Storage runtime opts by joining base_path and relative volume paths" do
    config = %{settings: %{"volumes" => [%{"name" => "archive", "path" => "archive"}]}}

    assert {:ok,
            [
              storage_config: [
                base_path: "priv/documents",
                volumes: volumes,
                default_volume: "archive"
              ]
            ]} =
             VolumeConfig.opts_for_channel_config(config)

    assert volumes == %{"archive" => "priv/documents/archive"}
  end

  test "requires configured base_path before runtime access" do
    Application.put_env(:zaq, Zaq.Storage, base_path: "")

    assert {:error, :storage_base_path_required} =
             VolumeConfig.opts_for_channel_config(%{
               settings: %{"volumes" => [%{"name" => "archive", "path" => "archive"}]}
             })
  end

  test "uses caller storage_config when atom-key settings have no configured base path" do
    assert {:error, :storage_base_path_required} =
             VolumeConfig.opts_for_channel_config(
               %{settings: %{"volumes" => [%{"name" => "archive", "path" => "archive"}]}},
               storage_config: [base_path: nil]
             )
  end

  test "accepts raw settings maps and resolves the default archive volume" do
    assert {:ok,
            [
              storage_config: [
                base_path: "priv/documents",
                volumes: %{"archive" => "priv/documents/archive"},
                default_volume: "archive"
              ]
            ]} =
             VolumeConfig.opts_for_channel_config(%{
               "volumes" => [%{"name" => "archive", "path" => "archive"}]
             })
  end

  test "atom-key embedded storage config overrides caller config" do
    assert {:ok,
            [
              storage_config: [
                base_path: "/configured/root",
                volumes: %{"archive" => "/configured/root/archive"},
                default_volume: "archive"
              ]
            ]} =
             VolumeConfig.opts_for_channel_config(
               %{
                 settings: %{"volumes" => [%{"name" => "archive", "path" => "archive"}]},
                 storage_config: [base_path: "/configured/root"]
               },
               storage_config: [base_path: "/caller/root"]
             )
  end

  test "string-key embedded storage config overrides caller config" do
    assert {:ok,
            [
              storage_config: [
                base_path: "/serialized/root",
                volumes: %{"archive" => "/serialized/root/archive"},
                default_volume: "archive"
              ]
            ]} =
             VolumeConfig.opts_for_channel_config(
               %{
                 "settings" => %{"volumes" => [%{"name" => "archive", "path" => "archive"}]},
                 "storage_config" => [base_path: "/serialized/root"]
               },
               storage_config: [base_path: "/caller/root"]
             )
  end
end
