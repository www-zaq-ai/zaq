defmodule ZaqWeb.Live.BO.DataSourceBrowserTest do
  use Zaq.DataCase, async: true

  alias ZaqWeb.Live.BO.DataSourceBrowser

  describe "source/2" do
    test "normalizes atom and string scope keys into a stable source" do
      config = %{id: 12, name: "Documents", provider: "disk"}

      source =
        DataSourceBrowser.source(config, %{
          "provider" => :disk,
          "config_id" => 34,
          scope_id: :volume_a,
          filters: %{"parent" => "volume-a"},
          label: "Volume A"
        })

      assert source.id == "disk:34:volume_a"
      assert source.provider == "disk"
      assert source.config_id == 34
      assert source.scope_id == "volume_a"
      assert source.filters == %{"parent" => "volume-a"}
      assert source.label == "Volume A"
    end
  end

  describe "navigation" do
    test "enters existing folders and ignores forged ids" do
      entries = [%{id: "a", name: "A", path: "a"}]

      assert DataSourceBrowser.enter_folder([], entries, "a") == entries
      assert DataSourceBrowser.enter_folder([], entries, "missing") == []
    end

    test "current folder falls back to source parent root" do
      source = %{filters: %{"parent" => "volume-a"}}

      assert DataSourceBrowser.current_folder(source, []).id == "volume-a"
      assert DataSourceBrowser.current_folder(source, [%{id: "child"}]).id == "child"
    end
  end

  describe "provider parameters" do
    test "builds list filters from source root and current parent" do
      source = %{config_id: 1, filters: %{"parent" => "volume-a"}}

      assert DataSourceBrowser.list_params(source, nil) == %{
               "config_id" => 1,
               "filters" => %{"parent" => "volume-a"},
               "include_permissions" => false
             }

      assert get_in(DataSourceBrowser.list_params(source, "child"), ["filters", "parent"]) ==
               "child"
    end

    test "builds CreateDocument folder params under selected source root" do
      source = %{provider: "disk", config_id: 7, filters: %{"parent" => "volume-a"}}

      assert DataSourceBrowser.create_folder_params(source, [], "New") == %{
               name: "New",
               kind: "folder",
               provider: "disk",
               config_id: "7",
               parent_id: "volume-a",
               path: "volume-a"
             }

      assert DataSourceBrowser.create_folder_params(
               source,
               [%{id: "opaque-folder-id", path: "Reports"}],
               "New"
             ) == %{
               name: "New",
               kind: "folder",
               provider: "disk",
               config_id: "7",
               parent_id: "opaque-folder-id",
               path: "volume-a/Reports"
             }
    end
  end
end
