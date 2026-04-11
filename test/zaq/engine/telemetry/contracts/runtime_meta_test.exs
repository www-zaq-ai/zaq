defmodule Zaq.Engine.Telemetry.Contracts.RuntimeMetaTest do
  use ExUnit.Case, async: true

  alias Zaq.Engine.Telemetry.Contracts.RuntimeMeta

  test "from_map(nil) returns default struct" do
    assert RuntimeMeta.from_map(nil) == %RuntimeMeta{}
  end

  test "from_map/1 reads href from atom key and drops href keys from extra" do
    meta = %{"href" => "/string", href: "/atom", keep: 1}

    assert RuntimeMeta.from_map(meta) == %RuntimeMeta{
             href: "/atom",
             extra: %{keep: 1}
           }
  end

  test "from_map/1 reads href from string key and drops href keys from extra" do
    meta = %{"href" => "/string", "keep" => 2, :href => nil}

    assert RuntimeMeta.from_map(meta) == %RuntimeMeta{
             href: "/string",
             extra: %{"keep" => 2}
           }
  end

  test "non-map input returns default struct" do
    assert RuntimeMeta.from_map("not a map") == %RuntimeMeta{}
  end
end
