defmodule Zaq.Utils.EmailUtilsTest do
  use ExUnit.Case, async: true

  alias Zaq.Utils.EmailUtils

  describe "normalize_message_id/1" do
    test "returns nil for nil" do
      assert EmailUtils.normalize_message_id(nil) == nil
    end

    test "strips angle brackets" do
      assert EmailUtils.normalize_message_id("<abc@example.com>") == "abc@example.com"
    end

    test "trims surrounding whitespace" do
      assert EmailUtils.normalize_message_id("  abc@example.com  ") == "abc@example.com"
    end

    test "returns nil for blank string" do
      assert EmailUtils.normalize_message_id("   ") == nil
    end

    test "returns nil for non-binary input (line 21)" do
      assert EmailUtils.normalize_message_id(123) == nil
      assert EmailUtils.normalize_message_id(:atom) == nil
    end
  end
end
