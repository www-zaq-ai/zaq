defmodule Zaq.Utils.MapTest do
  use ExUnit.Case, async: true

  alias Zaq.Utils.Map

  describe "read_any/2" do
    test "returns nil when map argument is invalid" do
      assert Map.read_any("not-a-map", [:subject, "subject"]) == nil
    end

    test "returns nil when keys argument is not a list" do
      assert Map.read_any(%{subject: "hello"}, :subject) == nil
    end
  end

  describe "metadata_subject/1" do
    test "returns nil for non-map string input" do
      assert Map.metadata_subject("not-a-map") == nil
    end

    test "returns nil for nil input" do
      assert Map.metadata_subject(nil) == nil
    end
  end
end
