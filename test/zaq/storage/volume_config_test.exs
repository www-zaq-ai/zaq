defmodule Zaq.Storage.VolumeConfigTest do
  use ExUnit.Case, async: false

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
             "volumes" => [%{"name" => "Archive", "path" => "archive"}]
           }
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

    assert {:ok, [storage_config: [base_path: "priv/documents", volumes: volumes]]} =
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
end
