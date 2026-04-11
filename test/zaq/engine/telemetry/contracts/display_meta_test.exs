defmodule Zaq.Engine.Telemetry.Contracts.DisplayMetaTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Telemetry.Contracts.DisplayMeta

  test "from_map(nil) returns default struct" do
    assert DisplayMeta.from_map(nil) == %DisplayMeta{}
  end

  test "from_map/1 reads range/hint/scope from atom keys" do
    meta = %{range: "24h", hint: "Rolling window", scope: "workspace", keep: 1}

    assert DisplayMeta.from_map(meta) == %DisplayMeta{
             range: "24h",
             hint: "Rolling window",
             scope: "workspace",
             extra: %{keep: 1}
           }
  end

  test "from_map/1 reads range/hint/scope from string keys" do
    meta = %{"range" => "7d", "hint" => "Trailing week", "scope" => "team", "keep" => 2}

    assert DisplayMeta.from_map(meta) == %DisplayMeta{
             range: "7d",
             hint: "Trailing week",
             scope: "team",
             extra: %{"keep" => 2}
           }
  end

  test "extra drops both atom/string range/hint/scope/href keys" do
    meta = %{
      :range => "24h",
      :hint => "atom hint",
      :scope => "atom scope",
      :href => "/atoms",
      "range" => "7d",
      "hint" => "string hint",
      "scope" => "string scope",
      "href" => "/strings",
      :keep_atom => true,
      "keep_string" => true
    }

    result = DisplayMeta.from_map(meta)

    assert result.extra == %{:keep_atom => true, "keep_string" => true}
  end

  test "non-map input returns default struct" do
    assert DisplayMeta.from_map("not a map") == %DisplayMeta{}
  end
end
