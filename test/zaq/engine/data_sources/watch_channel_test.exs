defmodule Zaq.Engine.DataSources.WatchChannelTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Zaq.Engine.DataSources.WatchChannel

  test "statuses/0 returns the expected statuses" do
    assert WatchChannel.statuses() == ~w(active error stopped)
  end

  test "target_kinds/0 returns the expected target kinds" do
    assert WatchChannel.target_kinds() == ~w(file collection folder)
  end

  test "changeset treats blank target_kind as no target_kind change" do
    changeset =
      WatchChannel.changeset(%WatchChannel{}, %{
        provider: "google_drive",
        target_kind: "",
        status: "active"
      })

    assert get_change(changeset, :provider) == "google_drive"
    assert get_change(changeset, :target_kind) == ""
    assert get_change(changeset, :status) == "active"
    refute changeset.valid?
  end

  test "changeset removes exact blank normalized field changes before validation/defaulting" do
    changeset =
      WatchChannel.changeset(%WatchChannel{}, %{
        provider: "",
        target_kind: "",
        status: ""
      })

    assert get_change(changeset, :provider) == ""
    assert get_change(changeset, :target_kind) == ""
    assert get_change(changeset, :status) == "active"
    refute changeset.valid?

    assert Keyword.get_values(changeset.errors, :target_kind) == [
             {"is invalid", [validation: :inclusion, enum: ["file", "collection", "folder"]]}
           ]
  end

  test "changeset ignores normalized fields without accepted string or atom changes" do
    changeset =
      WatchChannel.changeset(%WatchChannel{}, %{
        provider: false,
        target_kind: false,
        status: false
      })

    refute changeset.valid?

    assert {:provider, {"is invalid", [type: :string, validation: :cast]}} in changeset.errors
    assert {:target_kind, {"is invalid", [type: :string, validation: :cast]}} in changeset.errors
    assert {:status, {"is invalid", [type: :string, validation: :cast]}} in changeset.errors

    assert get_change(changeset, :provider) == ""
    assert get_change(changeset, :target_kind) == ""
    assert get_change(changeset, :status) == "active"
  end

  test "changeset leaves omitted normalized fields unchanged and defaults status" do
    changeset = WatchChannel.changeset(%WatchChannel{}, %{})

    assert get_change(changeset, :provider) == ""
    assert get_change(changeset, :target_kind) == ""
    assert get_change(changeset, :status) == "active"
    refute changeset.valid?
  end

  test "changeset preserves explicit nonblank status" do
    changeset =
      WatchChannel.changeset(%WatchChannel{}, %{
        target_kind: "folder",
        status: "stopped"
      })

    assert get_change(changeset, :status) == "stopped"
    assert changeset.valid?
  end
end
