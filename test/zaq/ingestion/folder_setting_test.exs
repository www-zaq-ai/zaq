defmodule Zaq.Ingestion.FolderSettingTest do
  use Zaq.DataCase, async: true

  alias Zaq.Ingestion.FolderSetting

  @valid_attrs %{volume_name: "default", folder_path: "docs/reports"}

  describe "changeset/2" do
    test "valid with required fields" do
      changeset = FolderSetting.changeset(%FolderSetting{}, @valid_attrs)
      assert changeset.valid?
    end

    test "invalid without volume_name" do
      changeset =
        FolderSetting.changeset(%FolderSetting{}, Map.delete(@valid_attrs, :volume_name))

      refute changeset.valid?
    end

    test "invalid without folder_path" do
      changeset =
        FolderSetting.changeset(%FolderSetting{}, Map.delete(@valid_attrs, :folder_path))

      refute changeset.valid?
    end

    test "defaults tags to empty list" do
      changeset = FolderSetting.changeset(%FolderSetting{}, @valid_attrs)
      assert Ecto.Changeset.get_field(changeset, :tags) == []
    end

    test "accepts tags" do
      attrs = Map.put(@valid_attrs, :tags, ["public"])
      changeset = FolderSetting.changeset(%FolderSetting{}, attrs)
      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :tags) == ["public"]
    end
  end

  describe "upsert/1" do
    test "inserts a new folder setting" do
      assert {:ok, setting} = FolderSetting.upsert(@valid_attrs)
      assert setting.volume_name == "default"
      assert setting.folder_path == "docs/reports"
      assert setting.tags == []
    end

    test "updates tags on conflict (same volume + path)" do
      {:ok, _} = FolderSetting.upsert(@valid_attrs)
      {:ok, updated} = FolderSetting.upsert(Map.put(@valid_attrs, :tags, ["public"]))
      assert updated.tags == ["public"]
    end

    test "different paths create separate records" do
      {:ok, s1} = FolderSetting.upsert(@valid_attrs)
      {:ok, s2} = FolderSetting.upsert(%{@valid_attrs | folder_path: "docs/other"})
      refute s1.id == s2.id
    end
  end

  describe "get/2" do
    test "returns setting by volume and path" do
      {:ok, _} = FolderSetting.upsert(Map.put(@valid_attrs, :tags, ["public"]))
      setting = FolderSetting.get("default", "docs/reports")
      assert setting.tags == ["public"]
    end

    test "returns nil when not found" do
      assert FolderSetting.get("default", "nonexistent") == nil
    end
  end
end
