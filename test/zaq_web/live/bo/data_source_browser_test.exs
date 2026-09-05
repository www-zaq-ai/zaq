defmodule ZaqWeb.Live.BO.DataSourceBrowserTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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

    test "uses provider and scope defaults when labels and names are absent" do
      config = %{id: 12, provider: "google_drive"}

      assert DataSourceBrowser.source(config, %{"scope_id" => "root"}) == %{
               id: "google_drive:12:root",
               provider: "google_drive",
               config_id: 12,
               scope_id: "root",
               filters: %{"parent" => "root"},
               label: "Google Drive",
               path: nil
             }
    end
  end

  describe "navigation" do
    test "selects the requested source and falls back to the first source" do
      sources = [%{id: "first"}, %{id: "second"}]

      assert DataSourceBrowser.active_source(sources, "second") == Enum.at(sources, 1)
      assert DataSourceBrowser.active_source(sources, "unknown") == Enum.at(sources, 0)
      assert DataSourceBrowser.active_source([], "unknown") == nil
    end

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

    property "up_stack removes exactly the final folder" do
      folder =
        gen all(
              id <- string(:alphanumeric, min_length: 1, max_length: 12),
              name <- string(:alphanumeric, min_length: 1, max_length: 12),
              path <- string(:alphanumeric, min_length: 1, max_length: 12)
            ) do
          %{id: id, name: name, path: path}
        end

      check all(
              prefix <- list_of(folder, max_length: 8),
              final_folder <- folder
            ) do
        assert DataSourceBrowser.up_stack(prefix ++ [final_folder]) == prefix
      end
    end

    test "up_stack returns an empty stack for an empty stack" do
      assert DataSourceBrowser.up_stack([]) == []
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

      assert DataSourceBrowser.list_params(source, "", true) == %{
               "config_id" => 1,
               "filters" => %{"parent" => "volume-a"},
               "include_permissions" => true
             }
    end

    test "builds destination params from an opaque folder id and path" do
      source = %{config_id: 7, filters: %{}}
      stack = [%{id: "opaque-folder-id", path: "Reports"}]

      assert DataSourceBrowser.destination_params(source, stack) == %{
               config_id: "7",
               parent_id: "opaque-folder-id",
               path: "Reports"
             }
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
