defmodule Zaq.MapUtilsTest do
  use ExUnit.Case, async: true

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
end
