defmodule Zaq.MapUtilsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.MapUtils

  describe "fetch_either/3" do
    test "returns atom-keyed value when present" do
      assert MapUtils.fetch_either(%{status: "active"}, :status, "status") == "active"
    end

    test "returns string-keyed value when atom key is absent" do
      assert MapUtils.fetch_either(%{"status" => "active"}, :status, "status") == "active"
    end

    test "atom key takes precedence when both keys are present" do
      assert MapUtils.fetch_either(%{"status" => "string", status: "atom"}, :status, "status") ==
               "atom"
    end

    test "returns nil when neither key is present" do
      assert MapUtils.fetch_either(%{}, :status, "status") == nil
    end

    test "falls back to string key when atom-keyed value is nil" do
      assert MapUtils.fetch_either(%{"status" => "active", status: nil}, :status, "status") ==
               "active"
    end
  end

  describe "fetch/2" do
    test "returns atom-keyed value when present" do
      assert MapUtils.fetch(%{status: "active"}, :status) == "active"
    end

    test "returns string-keyed value when atom key is absent" do
      assert MapUtils.fetch(%{"status" => "active"}, :status) == "active"
    end
  end

  describe "stringify_keys/1" do
    test "leaves string keys and non-atom keys unchanged" do
      input = %{"status" => "active", 123 => "numeric-key"}

      assert MapUtils.stringify_keys(input) == %{
               "status" => "active",
               123 => "numeric-key"
             }
    end

    test "converts atom keys and preserves string keys in the same map" do
      input = %{"scope" => "public", status: "active"}

      assert MapUtils.stringify_keys(input) == %{
               "status" => "active",
               "scope" => "public"
             }
    end

    property "is idempotent for atom and string keyed maps" do
      check all(
              key <- member_of([:status, :scope, "status", "scope"]),
              value <- string(:printable)
            ) do
        map = %{key => value}

        assert MapUtils.stringify_keys(MapUtils.stringify_keys(map)) ==
                 MapUtils.stringify_keys(map)
      end
    end
  end
end
